// ignore_for_file: unused_element, unused_field

import 'dart:convert';

import 'package:dio/dio.dart';

import '../dtos/naver_stock_dtos.dart';

abstract interface class NaverStockDataClient {
  Future<List<NaverAutocompleteItemDto>> searchStocks(String query);

  Future<Map<String, NaverRealtimeQuoteDto>> fetchRealtimeQuotes(
    Iterable<String> symbols,
  );

  Future<NaverChartMetadataDto> fetchChartMetadata(String symbol);

  Future<NaverDailyHistoryPageDto> fetchDailyHistoryPage({
    required String symbol,
    required int page,
  });
}

class NaverDomesticStockClient implements NaverStockDataClient {
  const NaverDomesticStockClient(this._dio);

  final Dio _dio;

  static const Map<String, String> _defaultHeaders = {
    'accept': 'application/json, text/plain, */*',
    'referer': 'https://m.stock.naver.com/',
    'accept-language': 'ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7',
    'user-agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/537.36 (KHTML, like Gecko) '
        'Chrome/123.0.0.0 Safari/537.36',
  };

  static Map<String, dynamic> _decodeJsonObjectBody(
    Object? data,
    String contextLabel,
  ) {
    if (data == null) {
      throw FormatException('$contextLabel response body is empty');
    }

    if (data is Map<String, dynamic>) {
      return data;
    }

    if (data is String) {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      throw FormatException('$contextLabel response is not a JSON object');
    }

    if (data is List<int>) {
      final decoded = jsonDecode(utf8.decode(data));
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      throw FormatException('$contextLabel response is not a JSON object');
    }

    if (data is Map) {
      return data.map((key, value) => MapEntry(key.toString(), value));
    }

    throw FormatException('$contextLabel response body has unsupported shape');
  }

  static Map<String, dynamic> _asStringKeyedMap(
    Object? value,
    String contextLabel,
  ) {
    if (value is Map<String, dynamic>) {
      return value;
    }

    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }

    throw FormatException('$contextLabel is not a JSON object');
  }

  @override
  Future<List<NaverAutocompleteItemDto>> searchStocks(String query) async {
    // 자동완성 응답이 문자열 그대로 오는 경우가 있어 ResponseType.plain으로 받고
    // _decodeJsonObjectBody에서 문자열/바이트/맵을 모두 흡수하도록 위임한다.
    final response = await _dio.get<Object?>(
      'https://ac.stock.naver.com/ac',
      queryParameters: {
        'q': query,
        'target': 'stock,ipo,index,marketindicator',
      },
      options: Options(
        headers: _defaultHeaders,
        responseType: ResponseType.plain,
      ),
    );

    final body = _decodeJsonObjectBody(response.data, 'Naver autocomplete');
    final rawItems = body['items'];
    if (rawItems is! List) {
      return const [];
    }

    return rawItems
        .map(
          (item) => NaverAutocompleteItemDto.fromJson(
            _asStringKeyedMap(item, 'Naver autocomplete item'),
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<Map<String, NaverRealtimeQuoteDto>> fetchRealtimeQuotes(
    Iterable<String> symbols,
  ) async {
    final uniqueSymbols = symbols.toSet();
    if (uniqueSymbols.isEmpty) {
      return const {};
    }

    // 2024-04 커밋에서 확인한 대로 실제 포맷은 SERVICE_ITEM 접두어 한 번에
    // 종목코드를 콤마로 이어붙이는 형태다 (파이프로 접두어를 반복하지 않음).
    final response = await _dio.get<Object?>(
      'https://polling.finance.naver.com/api/realtime',
      queryParameters: {'query': 'SERVICE_ITEM:${uniqueSymbols.join(',')}'},
      options: Options(
        headers: _defaultHeaders,
        responseType: ResponseType.plain,
      ),
    );

    final body = _decodeJsonObjectBody(response.data, 'Naver realtime quote');
    final result = _asStringKeyedMap(body['result'], 'Naver realtime result');
    final rawAreas = result['areas'];
    if (rawAreas is! List) {
      return const {};
    }

    final quotes = <String, NaverRealtimeQuoteDto>{};
    for (final rawArea in rawAreas) {
      final area = _asStringKeyedMap(rawArea, 'Naver realtime area');
      final rawDatas = area['datas'];
      if (rawDatas is! List) {
        continue;
      }
      for (final rawData in rawDatas) {
        final quote = NaverRealtimeQuoteDto.fromJson(
          _asStringKeyedMap(rawData, 'Naver realtime data'),
        );
        quotes[quote.symbol] = quote;
      }
    }

    return quotes;
  }

  @override
  Future<NaverChartMetadataDto> fetchChartMetadata(String symbol) async {
    // 이 엔드포인트는 항상 단일 JSON 객체를 반환하므로 별도 wrapper 탐색 없이
    // 바로 디코드해서 DTO로 변환한다.
    final response = await _dio.get<Object?>(
      'https://stock.naver.com/api/securityFe/api/fchart/domestic/stock/$symbol',
      options: Options(headers: _defaultHeaders),
    );

    final body = _decodeJsonObjectBody(response.data, 'Naver chart metadata');
    return NaverChartMetadataDto.fromJson(body);
  }

  @override
  Future<NaverDailyHistoryPageDto> fetchDailyHistoryPage({
    required String symbol,
    required int page,
  }) async {
    if (page < 1) {
      throw ArgumentError.value(page, 'page', 'page must be >= 1');
    }

    // 이 응답은 JSON이 아니라 EUC-KR 계열 HTML이라 바이트 그대로 받아서
    // latin1으로 디코드한다. 숫자/날짜 칸은 ASCII라 latin1로도 안전하게 읽히고,
    // 한글이 깨지더라도 이 메서드가 실제로 필요로 하는 값에는 영향이 없다.
    final response = await _dio.get<List<int>>(
      'https://finance.naver.com/item/sise_day.naver',
      queryParameters: {'code': symbol, 'page': page},
      options: Options(
        headers: _defaultHeaders,
        responseType: ResponseType.bytes,
      ),
    );

    final html = latin1.decode(response.data ?? const []);

    return NaverDailyHistoryPageDto(
      symbol: symbol,
      page: page,
      lastPage: _parseSiseDayLastPage(html),
      priceInfos: _parseSiseDayRows(html),
    );
  }
}

final RegExp _siseDayRowPattern = RegExp(
  r'<tr onmouseover="mouseOver\(this\)"[^>]*>(.*?)</tr>',
  dotAll: true,
);
final RegExp _siseDaySpanPattern = RegExp(r'<span[^>]*>([^<]*)</span>');
final RegExp _siseDayLastPagePattern = RegExp(
  r'class="pgRR"[^>]*>\s*<a[^>]*href="[^"]*[?&]page=(\d+)"',
  dotAll: true,
);

// 표의 한 행은 span 7개(날짜, 종가, 전일비, 시가, 고가, 저가, 거래량) 순서로
// 렌더링된다. 전일비(index 2)는 이미 changeRate 계산에 쓰지 않으므로 건너뛴다.
List<NaverHistoricalPriceDto> _parseSiseDayRows(String html) {
  final rows = <NaverHistoricalPriceDto>[];

  for (final rowMatch in _siseDayRowPattern.allMatches(html)) {
    final spans = _siseDaySpanPattern
        .allMatches(rowMatch.group(1)!)
        .map((match) => match.group(1)!.trim())
        .toList(growable: false);

    if (spans.length < 7 || spans.any((value) => value.isEmpty)) {
      continue;
    }

    rows.add(
      NaverHistoricalPriceDto.fromJson({
        'localDate': spans[0].replaceAll('.', ''),
        'closePrice': spans[1],
        'openPrice': spans[3],
        'highPrice': spans[4],
        'lowPrice': spans[5],
        'accumulatedTradingVolume': spans[6],
      }),
    );
  }

  return rows;
}

int _parseSiseDayLastPage(String html) {
  final match = _siseDayLastPagePattern.firstMatch(html);
  if (match == null) {
    return 1;
  }
  return int.parse(match.group(1)!);
}

double _parseDouble(String value) {
  return double.parse(value.replaceAll(',', ''));
}

int _parseInt(String value) {
  return int.parse(value.replaceAll(',', ''));
}

Map<String, String> naverDesktopLikeHeaders() =>
    Map<String, String>.unmodifiable(NaverDomesticStockClient._defaultHeaders);
