import 'package:flutter/material.dart';

import '../../../watchlist/domain/models/watchlist_models.dart';
import '../../../../theme/app_assets.dart';
import '../../../../theme/app_theme.dart';
import '../../domain/services/search_text_utils.dart';
import '../layout/search_layout_spec.dart';
import 'search_action_bar.dart';

class SearchResultRow extends StatelessWidget {
  const SearchResultRow({
    required this.item,
    required this.query,
    required this.isSelected,
    required this.layout,
    required this.onTap,
    required this.onHeartTap,
    required this.onActionTap,
    super.key,
  });

  final StockSearchItem item;
  final String query;
  final bool isSelected;
  final SearchLayoutSpec layout;
  final VoidCallback onTap;
  final VoidCallback onHeartTap;
  final ValueChanged<String> onActionTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('search-result-${item.id}'),
        onTap: onTap,
        child: Column(
          children: [
            SizedBox(
              key: Key('search-result-row-${item.id}'),
              height: SearchLayoutSpec.resultRowHeight,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: layout.horizontalPadding,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: _SearchTextColumn(item: item, query: query),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      key: Key('search-heart-${item.id}'),
                      onTap: onHeartTap,
                      behavior: HitTestBehavior.opaque,
                      child: AppAssetSlotIcon(
                        key: Key('search-heart-icon-${item.id}'),
                        assetPath: AppAssets.favoriteHeart,
                        // SearchToast의 하트(20x20)와 동일하게 맞춘 초안값.
                        // Figma 슬롯 크기 확인 후 조정 필요.
                        slotWidth: 20,
                        slotHeight: 20,
                        assetWidth: AppAssetSizes.favoriteHeart.width,
                        assetHeight: AppAssetSizes.favoriteHeart.height,
                        color: item.isFavorite
                            ? AppColors.mainAndAccent.up_f93f62
                            : AppColors.darkTheme.c_424242,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (isSelected) ...[
              const SizedBox(height: 0),
              Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: layout.horizontalPadding,
                ),
                child: SearchActionBar(
                  key: Key('search-actions-${item.id}'),
                  layout: layout,
                  onActionTap: onActionTap,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SearchTextColumn extends StatelessWidget {
  const _SearchTextColumn({required this.item, required this.query});

  final StockSearchItem item;
  final String query;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RichText(
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          text: _buildHighlightedSpan(
            text: item.name,
            query: query,
            // Figma 스펙: Bold(700). 공용 searchName은 SemiBold(600)라 이 화면만
            // 오버라이드한다.
            baseStyle: AppTypography.searchName.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 4),
        RichText(
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          text: _buildHighlightedSpan(
            text: buildSearchSubtitle(item),
            query: query,
            baseStyle: AppTypography.searchMeta,
          ),
        ),
      ],
    );
  }

  TextSpan _buildHighlightedSpan({
    required String text,
    required String query,
    required TextStyle baseStyle,
  }) {
    return TextSpan(
      children: splitSearchTextParts(text, query)
          .map(
            (part) => TextSpan(
              text: part.text,
              style: part.isHighlighted
                  ? baseStyle.copyWith(
                      color: AppColors.point.jongmoksearch_b980ff,
                    )
                  : baseStyle,
            ),
          )
          .toList(growable: false),
    );
  }
}
