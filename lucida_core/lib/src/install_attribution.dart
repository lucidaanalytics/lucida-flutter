import 'dart:convert';

import 'ports.dart';

/// Async source of `$app_installed` attribution props. Must complete (store-only props on failure).
typedef InstallSource = Future<Map<String, dynamic>> Function();

const _clickIds = ['gclid', 'gbraid', 'wbraid', 'fbclid', 'ttclid', 'msclkid'];
const _utm = ['source', 'medium', 'campaign', 'term', 'content'];

/// Maps a Play Install Referrer string (`utm_source=..&gclid=..`) plus timestamps (seconds) to `$app_installed` props.
Map<String, dynamic> installReferrerProps(String raw, {int? clickTs, int? beginTs}) {
  final q = <String, String>{};
  for (final part in raw.split('&')) {
    if (part.isEmpty) continue;
    final i = part.indexOf('=');
    final k = i < 0 ? part : part.substring(0, i);
    var v = i < 0 ? '' : part.substring(i + 1);
    try {
      v = Uri.decodeQueryComponent(v);
    } catch (_) {}
    q[k] = v;
  }
  return {
    '\$install_store': 'google_play',
    '\$install_referrer': raw,
    if (clickTs != null) '\$install_referrer_click_ts': clickTs,
    if (beginTs != null) '\$install_begin_ts': beginTs,
    for (final u in _utm)
      if ((q['utm_$u'] ?? '').isNotEmpty) '\$utm_$u': q['utm_$u'],
    for (final c in _clickIds)
      if ((q[c] ?? '').isNotEmpty) '\$$c': q[c],
  };
}

/// Maps an Apple Search Ads (AdServices) response body to `$app_installed` props; null/garbage -> store only.
Map<String, dynamic> appStoreInstallProps(String? responseJson) {
  final out = <String, dynamic>{'\$install_store': 'app_store'};
  if (responseJson == null) return out;
  Object? o;
  try {
    o = jsonDecode(responseJson);
  } catch (_) {
    return out;
  }
  if (o is! Map) return out;
  final attributed = o['attribution'] == true;
  out['\$install_adservices_attribution'] = attributed;
  if (!attributed) return out;
  out['\$utm_source'] = 'apple_search_ads';
  out['\$utm_medium'] = 'cpc';
  const map = [
    ['campaignId', '\$asa_campaign_id', '\$utm_campaign'],
    ['keywordId', '\$asa_keyword_id', '\$utm_term'],
    ['adGroupId', '\$asa_ad_group_id', '\$utm_content'],
    ['orgId', '\$asa_org_id', null],
    ['adId', '\$asa_ad_id', null],
    ['conversionType', '\$asa_conversion_type', null],
  ];
  for (final m in map) {
    final v = o[m[0]];
    if (v == null || '$v'.isEmpty) continue;
    out[m[1]!] = '$v';
    if (m[2] != null) out[m[2]!] = '$v';
  }
  return out;
}

const _asaUrl = 'https://api-adservices.apple.com/api/v1/';

/// Builds an [InstallSource] from a platform call returning `{platform: 'android', referrer, clickTs, beginTs}` or
/// `{platform: 'ios', token}` (null/throwing = unavailable). The iOS token is POSTed as text/plain; 404 is retried.
InstallSource installSourceFrom(Future<Map<dynamic, dynamic>?> Function() native, HttpPort http,
    {Duration retryDelay = const Duration(seconds: 5), int attempts = 3}) {
  return () async {
    try {
      final r = await native();
      if (r == null) return {};
      if (r['platform'] == 'android') {
        final ref = r['referrer'] as String?;
        if (ref == null) return {'\$install_store': 'google_play'};
        return installReferrerProps(ref, clickTs: r['clickTs'] as int?, beginTs: r['beginTs'] as int?);
      }
      final token = r['token'] as String?;
      if (token == null || token.isEmpty) return appStoreInstallProps(null);
      for (var i = 0; i < attempts; i++) {
        final res = await http.send('POST', _asaUrl, body: token, headers: {'Content-Type': 'text/plain'});
        if (res.status == 200) return appStoreInstallProps(res.body);
        if (res.status != 404 || i + 1 >= attempts) break;
        await Future<void>.delayed(retryDelay);
      }
      return appStoreInstallProps(null);
    } catch (_) {
      return {};
    }
  };
}
