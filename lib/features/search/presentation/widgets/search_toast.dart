import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../../theme/app_assets.dart';
import '../../../../theme/app_theme.dart';
import '../layout/search_layout_spec.dart';

class SearchToast extends StatelessWidget {
  const SearchToast({required this.layout, required this.message, super.key});

  final SearchLayoutSpec layout;
  final String message;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          height: SearchLayoutSpec.toastHeight,
          padding: EdgeInsets.symmetric(
            horizontal: 16 * layout.horizontalScale,
          ),
          decoration: BoxDecoration(
            color: AppDerivedColors.searchToastBackground,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppDerivedColors.searchToastBorder),
            boxShadow: const [
              BoxShadow(
                color: Color(0x40000000),
                blurRadius: 10,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              SizedBox(
                key: const Key('search-toast-favorite-icon'),
                width: 20,
                height: 20,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AppAssetSlotIcon(
                      assetPath: AppAssets.favoriteHeart,
                      slotWidth: 20,
                      slotHeight: 20,
                      assetWidth: AppAssetSizes.favoriteHeart.width,
                      assetHeight: AppAssetSizes.favoriteHeart.height,
                      color: AppColors.mainAndAccent.up_f93f62,
                    ),
                    Positioned(
                      // Figma 스펙은 6x4지만 하트 위에 얹으니 너무 작아 보여서
                      // 1.5배(9x6)로 시각적으로 키움.
                      right: 4.5,
                      top: 6,
                      left: 6.5,
                      bottom: 8,
                      child: AppAssetSlotIcon(
                        key: const Key('search-toast-check-icon'),
                        assetPath: AppAssets.toastCheck,
                        slotWidth: AppAssetSizes.toastCheck.width * 1.5,
                        slotHeight: AppAssetSizes.toastCheck.height * 1.5,
                        assetWidth: AppAssetSizes.toastCheck.width * 1.5,
                        assetHeight: AppAssetSizes.toastCheck.height * 1.5,
                        color: AppColors.text.text_fafafa,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: AppTypography.searchToast,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
