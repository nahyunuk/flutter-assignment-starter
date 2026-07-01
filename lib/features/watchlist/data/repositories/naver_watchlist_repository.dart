// ignore_for_file: unused_element, unused_field

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../domain/models/watchlist_models.dart';
import '../../domain/repositories/watchlist_repository.dart';
import '../../domain/services/watchlist_sorting.dart';
import '../clients/naver_domestic_stock_client.dart';
import '../clients/naver_stock_logo_url_resolver.dart';
import '../dtos/naver_stock_dtos.dart';
import 'favorite_ids_local_store.dart';

class NaverWatchlistRepository implements WatchlistRepository {
  NaverWatchlistRepository({
    required Dio dio,
    required FavoriteIdsLocalStore favoriteIdsLocalStore,
    NaverStockDataClient? client,
    NaverStockLogoUrlResolver? logoUrlResolver,
    this.realtimeCacheTtl = const Duration(seconds: 10),
    this.dailyHistoryFetchBatchSize = 4,
  }) : _client = client ?? NaverDomesticStockClient(dio),
       _favoriteIdsLocalStore = favoriteIdsLocalStore,
       _logoUrlResolver = logoUrlResolver ?? const NaverStockLogoUrlResolver();

  static const _historyRowsPerPage = 10;

  final NaverStockDataClient _client;
  final FavoriteIdsLocalStore _favoriteIdsLocalStore;
  final NaverStockLogoUrlResolver _logoUrlResolver;
  final Duration realtimeCacheTtl;
  final int dailyHistoryFetchBatchSize;

  final Map<String, NaverChartMetadataDto> _metadataCache = {};
  final Map<String, NaverDailyHistoryPageDto> _dailyHistoryPageCache = {};
  final Map<String, _RealtimeQuoteCacheEntry> _realtimeQuoteCache = {};

  Set<String>? _favoriteIdsCache;
  List<DateTime>? _availableDatesCache;

  @override
  Future<WatchlistSnapshot> fetchWatchlist({DateTime? asOf}) async {
    final favoriteIds = await loadFavoriteIds();
    final symbols = favoriteIds
        .map(domesticSymbolFromFavoriteId)
        .whereType<String>()
        .toSet()
        .toList(growable: false);

    if (symbols.isEmpty) {
      return WatchlistSnapshot(
        asOf: normalizeAsOfDate(asOf ?? DateTime.now()),
        items: const [],
      );
    }

    // 거래일 달력은 종목마다 다르지 않다고 가정하고 공용 fetchAvailableDates()를
    // 그대로 재사용한다(캐시되어 있으면 네트워크 호출 없이 바로 반환됨).
    final availableDates = await fetchAvailableDates();
    final latestDate = availableDates.isNotEmpty ? availableDates.first : null;
    final resolvedAsOf = _resolveAsOf(availableDates, asOf);
    final isLatestRequest = latestDate != null && resolvedAsOf == latestDate;

    final metadataBySymbol = await _loadMetadataBatch(symbols);
    // 과거 날짜 조회에는 실시간 시세가 의미 없으므로, 최신 날짜를 볼 때만 요청한다.
    final realtimeBySymbol = isLatestRequest
        ? await _loadRealtimeQuotes(symbols)
        : const <String, NaverRealtimeQuoteDto>{};

    final items = <WatchlistItem>[];
    for (final symbol in symbols) {
      final metadata = metadataBySymbol[symbol];
      if (metadata == null) {
        // 메타데이터 조회가 실패한 종목은 목록에서 조용히 제외한다.
        continue;
      }

      final historicalEntry = isLatestRequest
          ? await _loadLatestHistoricalEntry(symbol)
          : await _loadHistoricalEntryForDate(
              symbol: symbol,
              availableDates: availableDates,
              asOf: resolvedAsOf,
            );
      if (historicalEntry == null) {
        continue;
      }

      items.add(
        _buildWatchlistItem(
          symbol: symbol,
          metadata: metadata,
          historicalEntry: historicalEntry,
          realtimeQuote: realtimeBySymbol[symbol],
          latestDate: latestDate,
        ),
      );
    }

    return WatchlistSnapshot(
      asOf: resolvedAsOf,
      items: items,
      availableDates: availableDates,
    );
  }

  @override
  Future<List<DateTime>> fetchAvailableDates() async {
    final cached = _availableDatesCache;
    if (cached != null) {
      return List<DateTime>.unmodifiable(cached);
    }

    final favoriteIds = await loadFavoriteIds();
    String? referenceSymbol;
    for (final favoriteId in favoriteIds) {
      final symbol = domesticSymbolFromFavoriteId(favoriteId);
      if (symbol != null) {
        referenceSymbol = symbol;
        break;
      }
    }

    if (referenceSymbol == null) {
      _availableDatesCache = const [];
      return const [];
    }

    // lastPage를 알아야 전체 페이지 수를 알 수 있으므로 1페이지를 먼저 받는다.
    final firstPage = await _loadDailyHistoryPage(referenceSymbol, 1);
    final rows = <NaverHistoricalPriceDto>[...firstPage.priceInfos];

    // 남은 페이지는 dailyHistoryFetchBatchSize 단위로 묶어 동시에 요청한다.
    var nextPage = 2;
    while (nextPage <= firstPage.lastPage) {
      final batchEndPage = (nextPage + dailyHistoryFetchBatchSize - 1).clamp(
        nextPage,
        firstPage.lastPage,
      );
      final batchPages = await Future.wait([
        for (var page = nextPage; page <= batchEndPage; page += 1)
          _loadDailyHistoryPage(referenceSymbol, page),
      ]);
      for (final page in batchPages) {
        rows.addAll(page.priceInfos);
      }
      nextPage = batchEndPage + 1;
    }

    final dates =
        rows.map((row) => normalizeAsOfDate(row.localDate)).toSet().toList()
          ..sort((left, right) => right.compareTo(left));

    _availableDatesCache = dates;
    return List<DateTime>.unmodifiable(dates);
  }

  @override
  Future<WatchlistDetail> fetchWatchlistDetail({
    required String symbol,
    required MarketType market,
    DateTime? asOf,
  }) async {
    if (market != MarketType.domestic) {
      throw ArgumentError.value(
        market,
        'market',
        'NaverWatchlistRepository only supports domestic stocks',
      );
    }

    final availableDates = await fetchAvailableDates();
    final latestDate = availableDates.isNotEmpty ? availableDates.first : null;
    final resolvedAsOf = _resolveAsOf(availableDates, asOf);
    final isLatestRequest = latestDate != null && resolvedAsOf == latestDate;

    final selectedIndex = _indexOfDate(availableDates, resolvedAsOf) ?? 0;
    // "선택 날짜를 포함한 직전 30거래일" 이므로 selectedIndex부터 29일 더 과거까지
    // 자른다(달력에 그만큼 없으면 있는 만큼만 사용).
    final windowEndIndex = (selectedIndex + 29).clamp(
      0,
      availableDates.isEmpty ? 0 : availableDates.length - 1,
    );
    final windowDatesDescending = availableDates.isEmpty
        ? const <DateTime>[]
        : availableDates.sublist(selectedIndex, windowEndIndex + 1);

    final rowsByDate = await _loadHistoricalRowsForWindow(
      symbol: symbol,
      selectedIndex: selectedIndex,
      windowEndIndex: windowEndIndex,
    );
    final selectedRow = rowsByDate[_dateKey(resolvedAsOf)];
    if (selectedRow == null) {
      throw StateError(
        'No historical row found for $symbol at ${formatApiDate(resolvedAsOf)}',
      );
    }

    final previousClose = await _resolvePreviousClose(
      symbol: symbol,
      availableDates: availableDates,
      selectedIndex: selectedIndex,
      fallbackOpenPrice: selectedRow.openPrice,
      rowsByDate: rowsByDate,
    );

    // 과거 날짜 조회에는 실시간 시세가 의미 없으므로, 최신 날짜를 볼 때만 요청한다.
    final realtimeQuote = isLatestRequest
        ? (await _loadRealtimeQuotes({symbol}))[symbol]
        : null;

    final currentPrice = isLatestRequest && realtimeQuote != null
        ? realtimeQuote.currentPrice
        : selectedRow.closePrice;
    final changeAmount = currentPrice - previousClose;
    final changeRate = isLatestRequest && realtimeQuote != null
        ? realtimeQuote.changeRate
        : _percentChange(changeAmount, previousClose);
    final tradeVolume = isLatestRequest && realtimeQuote != null
        ? realtimeQuote.accumulatedTradingVolume
        : selectedRow.accumulatedTradingVolume;

    return WatchlistDetail(
      itemId: canonicalDomesticFavoriteId(symbol),
      symbol: symbol,
      market: MarketType.domestic,
      currency: 'KRW',
      currentPrice: currentPrice,
      changeAmount: changeAmount,
      changeRate: changeRate,
      tradeVolume: tradeVolume,
      volumeRatio: _volumeRatio(
        windowDatesDescending: windowDatesDescending,
        rowsByDate: rowsByDate,
      ),
      openPrice: selectedRow.openPrice,
      // 시가/고가/저가 등락률은 realtime 유무와 무관하게 항상 전일 종가 대비로
      // 계산한다(당일 장중 지표라 실시간 값으로 대체할 대상이 아님).
      openChangeRate: _percentChange(
        selectedRow.openPrice - previousClose,
        previousClose,
      ),
      highPrice: selectedRow.highPrice,
      highChangeRate: _percentChange(
        selectedRow.highPrice - previousClose,
        previousClose,
      ),
      lowPrice: selectedRow.lowPrice,
      lowChangeRate: _percentChange(
        selectedRow.lowPrice - previousClose,
        previousClose,
      ),
      candles: _candles(
        windowDatesDescending: windowDatesDescending,
        rowsByDate: rowsByDate,
      ),
    );
  }

  @override
  Future<List<StockSearchItem>> searchStocks({required String query}) async {
    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) {
      return const [];
    }

    final rawItems = await _client.searchStocks(trimmedQuery);
    final favoriteIds = await loadFavoriteIds();

    final seenSymbols = <String>{};
    final results = <StockSearchItem>[];

    for (final item in rawItems) {
      // 자동완성 결과에는 해외/지수 등도 섞여 오므로 국내 6자리 종목만 남기고,
      // 같은 종목이 여러 번 매칭되는 경우 첫 번째만 사용한다.
      if (!item.isDomesticStock || !seenSymbols.add(item.code)) {
        continue;
      }

      final canonicalId = canonicalDomesticFavoriteId(item.code);
      results.add(
        StockSearchItem(
          id: canonicalId,
          market: MarketType.domestic,
          marketLabel: item.typeName,
          symbol: item.code,
          name: item.name,
          isFavorite: favoriteIds.contains(canonicalId),
          logoUrl: _logoUrlResolver.resolveDomesticStockLogoUrl(item.code),
        ),
      );
    }

    return results;
  }

  @override
  Future<Set<String>> loadFavoriteIds() async {
    if (_favoriteIdsCache != null) {
      return Set<String>.unmodifiable(_favoriteIdsCache!);
    }

    final rawIds = await _favoriteIdsLocalStore.loadRawIds();
    final canonicalIds = rawIds.where(_isCanonicalFavoriteId).toSet();
    final hasLegacyOrInvalidIds =
        rawIds.isNotEmpty && canonicalIds.length != rawIds.length;

    final resolvedIds = !_favoriteIdsLocalStore.hasStoredIds
        ? <String>{...defaultNaverDomesticFavoriteIds}
        : hasLegacyOrInvalidIds
        ? <String>{...defaultNaverDomesticFavoriteIds}
        : canonicalIds;

    _favoriteIdsCache = resolvedIds;

    if (!setEquals(rawIds, resolvedIds)) {
      await _favoriteIdsLocalStore.saveRawIds(resolvedIds);
    }

    return Set<String>.unmodifiable(resolvedIds);
  }

  @override
  Future<void> addFavorite({required String itemId}) async {
    final canonicalId = _requireCanonicalFavoriteId(itemId);
    final favoriteIds = {...await loadFavoriteIds(), canonicalId};
    _favoriteIdsCache = favoriteIds;
    await _favoriteIdsLocalStore.saveRawIds(favoriteIds);
  }

  @override
  Future<void> removeFavorite({required String itemId}) async {
    final canonicalId = _requireCanonicalFavoriteId(itemId);
    final favoriteIds = {...await loadFavoriteIds()}..remove(canonicalId);
    _favoriteIdsCache = favoriteIds;
    await _favoriteIdsLocalStore.saveRawIds(favoriteIds);
  }

  Future<Map<String, NaverChartMetadataDto>> _loadMetadataBatch(
    List<String> symbols,
  ) async {
    final results = <String, NaverChartMetadataDto>{};
    for (final symbol in symbols) {
      try {
        results[symbol] = await _loadMetadata(symbol);
      } catch (error, stackTrace) {
        debugPrint('Skipping Naver metadata for $symbol: $error\n$stackTrace');
      }
    }
    return results;
  }

  Future<NaverChartMetadataDto> _loadMetadata(String symbol) async {
    final cached = _metadataCache[symbol];
    if (cached != null) {
      return cached;
    }

    final metadata = await _client.fetchChartMetadata(symbol);
    _metadataCache[symbol] = metadata;
    return metadata;
  }

  Future<NaverDailyHistoryPageDto> _loadDailyHistoryPage(
    String symbol,
    int page,
  ) async {
    final cacheKey = _dailyHistoryPageCacheKey(symbol, page);
    final cached = _dailyHistoryPageCache[cacheKey];
    if (cached != null) {
      return cached;
    }

    final historyPage = await _client.fetchDailyHistoryPage(
      symbol: symbol,
      page: page,
    );
    _dailyHistoryPageCache[cacheKey] = historyPage;
    return historyPage;
  }

  // selectedIndex~windowEndIndex 구간에 해당하는 페이지만 계산해서 불러오고,
  // 날짜 문자열을 키로 하는 조회용 맵으로 펼쳐 준다.
  Future<Map<String, NaverHistoricalPriceDto>> _loadHistoricalRowsForWindow({
    required String symbol,
    required int selectedIndex,
    required int windowEndIndex,
  }) async {
    final startPage = _pageNumberForIndex(selectedIndex);
    final endPage = _pageNumberForIndex(windowEndIndex);

    final rowsByDate = <String, NaverHistoricalPriceDto>{};
    for (var page = startPage; page <= endPage; page += 1) {
      final historyPage = await _loadDailyHistoryPage(symbol, page);
      for (final row in historyPage.priceInfos) {
        rowsByDate[_dateKey(row.localDate)] = row;
      }
    }
    return rowsByDate;
  }

  Future<Map<String, NaverRealtimeQuoteDto>> _loadRealtimeQuotes(
    Iterable<String> symbols,
  ) async {
    final requestedSymbols = symbols.toSet();
    final now = DateTime.now();
    final missingSymbols = <String>[];
    final quotes = <String, NaverRealtimeQuoteDto>{};

    for (final symbol in requestedSymbols) {
      final cached = _realtimeQuoteCache[symbol];
      final isFresh =
          cached != null &&
          now.difference(cached.fetchedAt) <= realtimeCacheTtl;
      if (isFresh) {
        quotes[symbol] = cached.quote;
      } else {
        missingSymbols.add(symbol);
      }
    }

    if (missingSymbols.isNotEmpty) {
      try {
        final fetchedQuotes = await _client.fetchRealtimeQuotes(missingSymbols);
        final fetchedAt = DateTime.now();
        for (final entry in fetchedQuotes.entries) {
          _realtimeQuoteCache[entry.key] = _RealtimeQuoteCacheEntry(
            quote: entry.value,
            fetchedAt: fetchedAt,
          );
          quotes[entry.key] = entry.value;
        }
      } catch (error, stackTrace) {
        debugPrint(
          'Falling back to historical-only Naver data for realtime batch: '
          '$error\n$stackTrace',
        );
      }
    }

    return quotes;
  }

  Future<_HistoricalEntry?> _loadHistoricalEntryForDate({
    required String symbol,
    required List<DateTime> availableDates,
    required DateTime asOf,
  }) async {
    final selectedIndex = _indexOfDate(availableDates, asOf);
    if (selectedIndex == null) {
      return null;
    }

    final selectedPageNumber = _pageNumberForIndex(selectedIndex);
    final selectedPage = await _loadDailyHistoryPage(
      symbol,
      selectedPageNumber,
    );
    final selectedRow = _rowForDate(selectedPage.priceInfos, asOf);
    if (selectedRow == null) {
      return null;
    }

    final previousClose = await _resolvePreviousClose(
      symbol: symbol,
      availableDates: availableDates,
      selectedIndex: selectedIndex,
      fallbackOpenPrice: selectedRow.openPrice,
      rowsByDate: {
        for (final row in selectedPage.priceInfos) _dateKey(row.localDate): row,
      },
    );

    return _HistoricalEntry(row: selectedRow, previousClose: previousClose);
  }

  Future<_HistoricalEntry?> _loadLatestHistoricalEntry(String symbol) async {
    final firstPage = await _loadDailyHistoryPage(symbol, 1);
    if (firstPage.priceInfos.isEmpty) {
      return null;
    }

    final selectedRow = firstPage.priceInfos.first;
    double previousClose = selectedRow.openPrice;
    if (firstPage.priceInfos.length > 1) {
      previousClose = firstPage.priceInfos[1].closePrice;
    } else {
      final nextPageRows = (await _loadDailyHistoryPage(symbol, 2)).priceInfos;
      if (nextPageRows.isNotEmpty) {
        previousClose = nextPageRows.first.closePrice;
      }
    }

    return _HistoricalEntry(row: selectedRow, previousClose: previousClose);
  }

  Future<double> _resolvePreviousClose({
    required String symbol,
    required List<DateTime> availableDates,
    required int selectedIndex,
    required double fallbackOpenPrice,
    required Map<String, NaverHistoricalPriceDto> rowsByDate,
  }) async {
    if (selectedIndex >= availableDates.length - 1) {
      return fallbackOpenPrice;
    }

    final previousDate = availableDates[selectedIndex + 1];
    final previousRowFromCache = rowsByDate[_dateKey(previousDate)];
    if (previousRowFromCache != null) {
      return previousRowFromCache.closePrice;
    }

    final page = await _loadDailyHistoryPage(
      symbol,
      _pageNumberForIndex(selectedIndex + 1),
    );
    final previousRow = _rowForDate(page.priceInfos, previousDate);
    return previousRow?.closePrice ?? fallbackOpenPrice;
  }

  WatchlistItem _buildWatchlistItem({
    required String symbol,
    required NaverChartMetadataDto metadata,
    required _HistoricalEntry historicalEntry,
    required NaverRealtimeQuoteDto? realtimeQuote,
    required DateTime? latestDate,
  }) {
    final isLatest =
        latestDate != null &&
        normalizeAsOfDate(historicalEntry.row.localDate) == latestDate;
    final currentPrice = isLatest && realtimeQuote != null
        ? realtimeQuote.currentPrice
        : historicalEntry.row.closePrice;
    final changeRate = isLatest && realtimeQuote != null
        ? realtimeQuote.changeRate
        : _percentChange(
            currentPrice - historicalEntry.previousClose,
            historicalEntry.previousClose,
          );
    final tradeVolume = isLatest && realtimeQuote != null
        ? realtimeQuote.accumulatedTradingVolume
        : historicalEntry.row.accumulatedTradingVolume;
    final marketCap = realtimeQuote == null
        ? 0
        : (realtimeQuote.countOfListedStock * realtimeQuote.currentPrice)
              .round();

    return WatchlistItem(
      id: canonicalDomesticFavoriteId(symbol),
      market: MarketType.domestic,
      symbol: symbol,
      name: metadata.stockName,
      currency: 'KRW',
      currentPrice: currentPrice,
      changeRate: changeRate,
      tradeVolume: tradeVolume,
      marketCap: marketCap,
      logoUrl: _logoUrlResolver.resolveDomesticStockLogoUrl(symbol),
    );
  }

  DateTime _resolveAsOf(
    List<DateTime> availableDates,
    DateTime? requestedAsOf,
  ) {
    if (availableDates.isEmpty) {
      return normalizeAsOfDate(requestedAsOf ?? DateTime.now());
    }

    if (requestedAsOf == null) {
      return availableDates.first;
    }

    final normalizedAsOf = normalizeAsOfDate(requestedAsOf);
    for (final date in availableDates) {
      if (date == normalizedAsOf) {
        return date;
      }
    }

    return availableDates.first;
  }

  int? _indexOfDate(List<DateTime> availableDates, DateTime asOf) {
    final normalizedAsOf = normalizeAsOfDate(asOf);
    for (var index = 0; index < availableDates.length; index += 1) {
      if (availableDates[index] == normalizedAsOf) {
        return index;
      }
    }
    return null;
  }

  int _pageNumberForIndex(int index) {
    return (index ~/ _historyRowsPerPage) + 1;
  }

  NaverHistoricalPriceDto? _rowForDate(
    Iterable<NaverHistoricalPriceDto> rows,
    DateTime date,
  ) {
    final dateKey = _dateKey(date);
    for (final row in rows) {
      if (_dateKey(row.localDate) == dateKey) {
        return row;
      }
    }
    return null;
  }

  double _volumeRatio({
    required List<DateTime> windowDatesDescending,
    required Map<String, NaverHistoricalPriceDto> rowsByDate,
  }) {
    if (windowDatesDescending.isEmpty) {
      return 0;
    }

    final selectedRow = rowsByDate[_dateKey(windowDatesDescending.first)];
    if (selectedRow == null) {
      return 0;
    }

    final previousVolumes = <int>[];
    for (
      var index = 1;
      index < windowDatesDescending.length && previousVolumes.length < 5;
      index += 1
    ) {
      final row = rowsByDate[_dateKey(windowDatesDescending[index])];
      if (row != null) {
        previousVolumes.add(row.accumulatedTradingVolume);
      }
    }

    if (previousVolumes.isEmpty) {
      return 0;
    }

    final averageVolume =
        previousVolumes.reduce((left, right) => left + right) /
        previousVolumes.length;
    if (averageVolume == 0) {
      return 0;
    }

    return double.parse(
      (selectedRow.accumulatedTradingVolume / averageVolume).toStringAsFixed(2),
    );
  }

  List<CandlePoint> _candles({
    required List<DateTime> windowDatesDescending,
    required Map<String, NaverHistoricalPriceDto> rowsByDate,
  }) {
    return windowDatesDescending.reversed
        .map((date) => rowsByDate[_dateKey(date)])
        .whereType<NaverHistoricalPriceDto>()
        .map(
          (item) => CandlePoint(
            time: item.localDate,
            open: item.openPrice,
            high: item.highPrice,
            low: item.lowPrice,
            close: item.closePrice,
            direction: directionFromDelta(item.closePrice - item.openPrice),
          ),
        )
        .toList(growable: false);
  }

  bool _isCanonicalFavoriteId(String itemId) {
    return domesticSymbolFromFavoriteId(itemId) != null;
  }

  String _requireCanonicalFavoriteId(String itemId) {
    final symbol = domesticSymbolFromFavoriteId(itemId);
    if (symbol == null) {
      throw ArgumentError.value(
        itemId,
        'itemId',
        'Naver repository only accepts canonical domestic favorite ids',
      );
    }
    return canonicalDomesticFavoriteId(symbol);
  }

  String _dailyHistoryPageCacheKey(String symbol, int page) => '$symbol::$page';

  String _dateKey(DateTime value) => formatApiDate(value);

  double _percentChange(double delta, double base) {
    if (base == 0) {
      return 0;
    }
    return double.parse(((delta / base) * 100).toStringAsFixed(2));
  }
}

class _RealtimeQuoteCacheEntry {
  const _RealtimeQuoteCacheEntry({
    required this.quote,
    required this.fetchedAt,
  });

  final NaverRealtimeQuoteDto quote;
  final DateTime fetchedAt;
}

class _HistoricalEntry {
  const _HistoricalEntry({required this.row, required this.previousClose});

  final NaverHistoricalPriceDto row;
  final double previousClose;
}
