// ignore_for_file: unused_element

import '../../domain/services/watchlist_sorting.dart';

class NaverAutocompleteItemDto {
  const NaverAutocompleteItemDto({
    required this.code,
    required this.name,
    required this.typeCode,
    required this.typeName,
    required this.url,
    required this.nationCode,
    required this.category,
  });

  factory NaverAutocompleteItemDto.fromJson(Map<String, dynamic> json) {
    // Naver autocomplete 응답의 키가 모델 필드명과 1:1로 대응해서 별도 매핑 없이
    // _readString으로 그대로 읽는다. (빈 문자열/누락 값은 FormatException으로 방어)
    return NaverAutocompleteItemDto(
      code: _readString(json['code']),
      name: _readString(json['name']),
      typeCode: _readString(json['typeCode']),
      typeName: _readString(json['typeName']),
      url: _readString(json['url']),
      nationCode: _readString(json['nationCode']),
      category: _readString(json['category']),
    );
  }

  final String code;
  final String name;
  final String typeCode;
  final String typeName;
  final String url;
  final String nationCode;
  final String category;

  bool get isDomesticStock =>
      category == 'stock' &&
      nationCode == 'KOR' &&
      RegExp(r'^\d{6}$').hasMatch(code) &&
      url.contains('/domestic/stock/');
}

class NaverRealtimeQuoteDto {
  const NaverRealtimeQuoteDto({
    required this.symbol,
    required this.currentPrice,
    required this.previousClose,
    required this.openPrice,
    required this.highPrice,
    required this.lowPrice,
    required this.accumulatedTradingVolume,
    required this.countOfListedStock,
  });

  factory NaverRealtimeQuoteDto.fromJson(Map<String, dynamic> json) {
    // 실시간 시세 응답은 축약된 키(cd/nv/pcv 등)를 쓰므로 의미가 드러나는 필드명으로
    // 옮겨 담는다. countOfListedStock은 응답에 없을 수 있어 _readNullableInt로 읽고
    // 없으면 시가총액 계산에서 0으로 처리되도록 0을 기본값으로 둔다.
    return NaverRealtimeQuoteDto(
      symbol: _readString(json['cd']),
      currentPrice: _readDouble(json['nv']),
      previousClose: _readDouble(json['pcv']),
      openPrice: _readDouble(json['ov']),
      highPrice: _readDouble(json['hv']),
      lowPrice: _readDouble(json['lv']),
      accumulatedTradingVolume: _readInt(json['aq']),
      countOfListedStock: _readNullableInt(json['countOfListedStock']) ?? 0,
    );
  }

  final String symbol;
  final double currentPrice;
  final double previousClose;
  final double openPrice;
  final double highPrice;
  final double lowPrice;
  final int accumulatedTradingVolume;
  final int countOfListedStock;

  double get changeAmount => currentPrice - previousClose;

  double get changeRate {
    if (previousClose == 0) {
      return 0;
    }
    return double.parse(
      (((currentPrice - previousClose) / previousClose) * 100).toStringAsFixed(
        2,
      ),
    );
  }
}

class NaverChartMetadataDto {
  const NaverChartMetadataDto({
    required this.symbol,
    required this.stockName,
    required this.stockExchangeNameKor,
  });

  factory NaverChartMetadataDto.fromJson(Map<String, dynamic> json) {
    // fchart 메타데이터 응답의 symbolCode를 symbol로 옮겨 다른 DTO와 네이밍을
    // 통일한다(나머지 두 필드는 응답 키와 이름이 같음).
    return NaverChartMetadataDto(
      symbol: _readString(json['symbolCode']),
      stockName: _readString(json['stockName']),
      stockExchangeNameKor: _readString(json['stockExchangeNameKor']),
    );
  }

  final String symbol;
  final String stockName;
  final String stockExchangeNameKor;
}

class NaverHistoricalPriceDto {
  const NaverHistoricalPriceDto({
    required this.localDate,
    required this.closePrice,
    required this.openPrice,
    required this.highPrice,
    required this.lowPrice,
    required this.accumulatedTradingVolume,
  });

  factory NaverHistoricalPriceDto.fromJson(Map<String, dynamic> json) {
    // 일별 시세 값들은 쉼표 포함 숫자 문자열로 올 수 있어 _readDouble/_readInt를
    // 사용하고, localDate(yyyyMMdd)는 _readLocalDate로 정규화한 DateTime으로 만든다.
    return NaverHistoricalPriceDto(
      localDate: _readLocalDate(json['localDate']),
      closePrice: _readDouble(json['closePrice']),
      openPrice: _readDouble(json['openPrice']),
      highPrice: _readDouble(json['highPrice']),
      lowPrice: _readDouble(json['lowPrice']),
      accumulatedTradingVolume: _readInt(json['accumulatedTradingVolume']),
    );
  }

  final DateTime localDate;
  final double closePrice;
  final double openPrice;
  final double highPrice;
  final double lowPrice;
  final int accumulatedTradingVolume;
}

class NaverHistoricalChartDto {
  const NaverHistoricalChartDto({
    required this.symbol,
    required this.periodType,
    required this.priceInfos,
  });

  factory NaverHistoricalChartDto.fromJson(Map<String, dynamic> json) {
    // 차트 래퍼는 종목코드를 code 키로 내려주고, priceInfos는 각 행을
    // NaverHistoricalPriceDto.fromJson으로 변환해 리스트로 모은다.
    final rawPriceInfos = json['priceInfos'];
    final priceInfos = rawPriceInfos is List
        ? rawPriceInfos
              .map(
                (entry) => NaverHistoricalPriceDto.fromJson(
                  entry as Map<String, dynamic>,
                ),
              )
              .toList(growable: false)
        : const <NaverHistoricalPriceDto>[];

    return NaverHistoricalChartDto(
      symbol: _readString(json['code']),
      periodType: _readString(json['periodType']),
      priceInfos: priceInfos,
    );
  }

  final String symbol;
  final String periodType;
  final List<NaverHistoricalPriceDto> priceInfos;
}

class NaverDailyHistoryPageDto {
  const NaverDailyHistoryPageDto({
    required this.symbol,
    required this.page,
    required this.lastPage,
    required this.priceInfos,
  });

  final String symbol;
  final int page;
  final int lastPage;
  final List<NaverHistoricalPriceDto> priceInfos;
}

DateTime _readLocalDate(Object? value) {
  final text = _readString(value);
  if (text.length != 8) {
    throw FormatException('Invalid Naver localDate "$text"');
  }

  return normalizeAsOfDate(
    DateTime(
      int.parse(text.substring(0, 4)),
      int.parse(text.substring(4, 6)),
      int.parse(text.substring(6, 8)),
    ),
  );
}

String _readString(Object? value) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) {
    throw FormatException('Missing string value for "$value"');
  }
  return text;
}

double _readDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  return double.parse(_readString(value).replaceAll(',', ''));
}

int _readInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return int.parse(_readString(value).replaceAll(',', ''));
}

int? _readNullableInt(Object? value) {
  if (value == null) {
    return null;
  }
  return _readInt(value);
}
