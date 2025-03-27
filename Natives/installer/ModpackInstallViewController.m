#import "AFNetworking.h"
#import "LauncherNavigationController.h"
#import "ModpackInstallViewController.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "WFWorkflowProgressView.h"
#import "modpack/ModpackUtils.h"
#import "modpack/ModrinthAPI.h"
#import "config.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#include <dlfcn.h>
#include <objc/runtime.h>

#pragma mark - Custom Cell Definition

// Modern custom cell for modpack display
@interface ModpackVersionCell : UITableViewCell
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) UIImageView *modpackIconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UIScrollView *tagsScrollView;
@property (nonatomic, strong) NSMutableArray<UIView *> *tagViews;
@property (nonatomic, assign) BOOL shouldTriggerClick;
@property (nonatomic, strong) UIVisualEffectView *backgroundBlurView;
@end

@implementation ModpackVersionCell

// Helper method for WebP URL conversion
- (NSString *)convertWebPUrl:(NSString *)imageUrl {
    if (!imageUrl || imageUrl.length == 0) {
        return imageUrl;
    }
    
    // Use a static cache to avoid converting the same URLs repeatedly
    static NSCache *webpUrlCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        webpUrlCache = [[NSCache alloc] init];
        webpUrlCache.countLimit = 200; // Limit cache size
    });
    
    // Check if we already converted this URL
    NSString *cachedUrl = [webpUrlCache objectForKey:imageUrl];
    if (cachedUrl) {
        return cachedUrl;
    }
    
    // Handle WebP format by requesting PNG instead
    if ([imageUrl.lowercaseString hasSuffix:@".webp"]) {
        NSString *convertedUrl = nil;
        
        // 1. For Modrinth CDN: Add format=png parameter
        if ([imageUrl containsString:@"cdn.modrinth.com"]) {
            NSURL *url = [NSURL URLWithString:imageUrl];
            
            // Parse existing query items to preserve them
            NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
            NSMutableArray *queryItems = [NSMutableArray array];
            
            if (components.queryItems) {
                [queryItems addObjectsFromArray:components.queryItems];
            }
            
            // Check if format parameter already exists
            BOOL hasFormatParam = NO;
            for (NSURLQueryItem *item in queryItems) {
                if ([item.name isEqualToString:@"format"]) {
                    hasFormatParam = YES;
                    break;
                }
            }
            
            // Add format parameter if needed
            if (!hasFormatParam) {
                [queryItems addObject:[NSURLQueryItem queryItemWithName:@"format" value:@"png"]];
                components.queryItems = queryItems;
                convertedUrl = components.URL.absoluteString;
            } else {
                convertedUrl = imageUrl;
            }
        } else {
            // 2. For other services: Try changing extension
            convertedUrl = [imageUrl stringByReplacingOccurrencesOfString:@".webp" 
                                                               withString:@".png" 
                                                                  options:NSCaseInsensitiveSearch 
                                                                    range:NSMakeRange(0, imageUrl.length)];
        }
        
        // Cache the converted URL for future use
        if (convertedUrl) {
            [webpUrlCache setObject:convertedUrl forKey:imageUrl];
            return convertedUrl;
        }
    }
    
    return imageUrl;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        // Prepare the cell with modern styling
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        
        // Add a shadow to give the cell a "card" appearance
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(0, 1);
        self.layer.shadowOpacity = 0.1;
        self.layer.shadowRadius = 4;
        
        // Container view with proper insets and rounded corners
        self.containerView = [[UIView alloc] init];
        self.containerView.translatesAutoresizingMaskIntoConstraints = NO;
        self.containerView.backgroundColor = [UIColor secondarySystemBackgroundColor];
        self.containerView.layer.cornerRadius = 12;
        self.containerView.layer.masksToBounds = YES;
        self.containerView.clipsToBounds = YES;
        [self.contentView addSubview:self.containerView];
        
        // Modpack icon - circular with auto sizing and shadow
        self.modpackIconView = [[UIImageView alloc] init];
        self.modpackIconView.translatesAutoresizingMaskIntoConstraints = NO;
        self.modpackIconView.contentMode = UIViewContentModeScaleAspectFill;
        self.modpackIconView.clipsToBounds = YES;
        self.modpackIconView.layer.cornerRadius = 24; // Larger, more prominent icon
        self.modpackIconView.backgroundColor = [UIColor systemGray6Color];
        self.modpackIconView.layer.borderWidth = 2.0;
        self.modpackIconView.layer.borderColor = [UIColor systemBackgroundColor].CGColor;
        [self.containerView addSubview:self.modpackIconView];
        
        // Title label (main title) - bolder font with dynamic text sizing
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.adjustsFontForContentSizeCategory = YES; // Support dynamic type
        self.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.containerView addSubview:self.titleLabel];
        
        // Subtitle label - smaller, secondary text with dynamic sizing
        self.subtitleLabel = [[UILabel alloc] init];
        self.subtitleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
        self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
        self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.subtitleLabel.adjustsFontForContentSizeCategory = YES; // Support dynamic type
        self.subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        self.subtitleLabel.numberOfLines = 2;
        [self.containerView addSubview:self.subtitleLabel];
        
        // Tags scroll view - for multiple category tags with better visual styling
        self.tagsScrollView = [[UIScrollView alloc] init];
        self.tagsScrollView.translatesAutoresizingMaskIntoConstraints = NO;
        self.tagsScrollView.showsHorizontalScrollIndicator = NO;
        self.tagsScrollView.showsVerticalScrollIndicator = NO;
        self.tagsScrollView.clipsToBounds = YES;
        [self.containerView addSubview:self.tagsScrollView];
        
        // Initialize tag views array
        self.tagViews = [NSMutableArray array];
        
        // Add disclosure indicator with more modern styling
        UIImageView *chevronView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        chevronView.tintColor = [UIColor systemGrayColor];
        chevronView.translatesAutoresizingMaskIntoConstraints = NO;
        chevronView.contentMode = UIViewContentModeScaleAspectFit;
        [self.containerView addSubview:chevronView];
        
        // Container view constraints - full content view with padding
        [NSLayoutConstraint activateConstraints:@[
            [self.containerView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],
            [self.containerView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8],
            [self.containerView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [self.containerView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16]
        ]];
        
        // Icon constraints - fixed size and positioned at start
        [NSLayoutConstraint activateConstraints:@[
            [self.modpackIconView.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor constant:12],
            [self.modpackIconView.centerYAnchor constraintEqualToAnchor:self.containerView.centerYAnchor],
            [self.modpackIconView.widthAnchor constraintEqualToConstant:48], // Larger icon
            [self.modpackIconView.heightAnchor constraintEqualToConstant:48] // Larger icon
        ]];
        
        // Chevron constraints
        [NSLayoutConstraint activateConstraints:@[
            [chevronView.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-16],
            [chevronView.centerYAnchor constraintEqualToAnchor:self.containerView.centerYAnchor],
            [chevronView.widthAnchor constraintEqualToConstant:20],
            [chevronView.heightAnchor constraintEqualToConstant:20]
        ]];
        
        // Title label constraints - positioned after icon with more spacing
        [NSLayoutConstraint activateConstraints:@[
            [self.titleLabel.topAnchor constraintEqualToAnchor:self.containerView.topAnchor constant:12],
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.modpackIconView.trailingAnchor constant:16],
            [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:chevronView.leadingAnchor constant:-8]
        ]];
        
        // Subtitle label constraints - below title with proper spacing
        [NSLayoutConstraint activateConstraints:@[
            [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:4],
            [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.titleLabel.trailingAnchor]
        ]];
        
        // Tags scroll view constraints with better positioning
        [NSLayoutConstraint activateConstraints:@[
            [self.tagsScrollView.topAnchor constraintEqualToAnchor:self.subtitleLabel.bottomAnchor constant:8],
            [self.tagsScrollView.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.tagsScrollView.trailingAnchor constraintEqualToAnchor:chevronView.leadingAnchor constant:-8],
            [self.tagsScrollView.heightAnchor constraintEqualToConstant:26], // Slightly taller for better readability
            [self.tagsScrollView.bottomAnchor constraintLessThanOrEqualToAnchor:self.containerView.bottomAnchor constant:-12]
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    
    // Reset the image view to avoid image flicker between cells
    // First cancel any active download to prevent callback race conditions
    if (self.modpackIconView) {
        [self.modpackIconView cancelImageDownloadTask];
        self.modpackIconView.image = [UIImage imageNamed:@"DefaultProfile"];
    }
    
    // Reset the title and subtitle to ensure they're cleared for reuse
    if (self.titleLabel) {
        self.titleLabel.text = nil;
        self.titleLabel.attributedText = nil;
    }
    
    if (self.subtitleLabel) {
        self.subtitleLabel.text = nil;
    }
    
    // Clear existing tag views
    for (UIView *tagView in self.tagViews) {
        [tagView removeFromSuperview];
    }
    [self.tagViews removeAllObjects];
    
    // Reset the scroll view content size
    if (self.tagsScrollView) {
        self.tagsScrollView.contentSize = CGSizeZero;
    }
    
    // Reset accessory view if needed
    self.accessoryType = UITableViewCellAccessoryNone;
    self.accessoryView = nil;
    
    // Clear any associated objects
    objc_setAssociatedObject(self, @"lastUpdateTime", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, @"lastPercentage", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, @"cellUpdateKey", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (UIColor *)colorForTag:(NSString *)tag {
    // Enhanced category color mapping with semantically appropriate colors
    static NSDictionary *tagColors = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tagColors = @{
            // Core gameplay categories
            @"adventure": [UIColor systemGreenColor],          // Green: exploration, nature
            @"challenging": [UIColor systemRedColor],          // Red: danger, difficulty
            @"combat": [UIColor systemOrangeColor],            // Orange: action, intensity
            @"kitchen sink": [UIColor systemPurpleColor],      // Purple: variety, abundance
            @"lightweight": [UIColor systemTealColor],         // Teal: light, breezy
            @"magic": [UIColor systemBlueColor],               // Blue: mystical, arcane
            @"multiplayer": [UIColor systemIndigoColor],       // Indigo: social, connectivity
            @"optimization": [UIColor colorWithRed:0.0 green:0.8 blue:0.9 alpha:1.0], // Cyan: efficiency, performance
            @"quests": [UIColor systemYellowColor],            // Yellow: rewards, achievements
            @"technology": [UIColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:1.0], // Gray: industrial, mechanical
            
            // Additional categories for better coverage
            @"building": [UIColor colorWithRed:0.76 green:0.60 blue:0.42 alpha:1.0], // Brown: construction
            @"exploration": [UIColor systemGreenColor],        // Same as adventure
            @"survival": [UIColor systemOrangeColor],          // Survival-oriented
            @"rpg": [UIColor systemPinkColor],                 // Pink: role-playing, fantasy
            @"skyblock": [UIColor colorWithRed:0.53 green:0.81 blue:0.92 alpha:1.0], // Light blue: sky theme
            @"mini game": [UIColor systemYellowColor],         // Mini-games like quests
            @"modded": [UIColor systemPurpleColor],            // General modded category
            @"fabric": [UIColor colorWithRed:0.31 green:0.31 blue:0.31 alpha:1.0],  // Dark gray: Fabric loader
            @"forge": [UIColor colorWithRed:0.60 green:0.40 blue:0.20 alpha:1.0],   // Bronze: Forge loader
            @"vanilla+": [UIColor colorWithRed:0.82 green:0.71 blue:0.55 alpha:1.0] // Vanilla enhanced
        };
    });
    
    // Convert tag to lowercase for case-insensitive matching
    NSString *lowercaseTag = [tag lowercaseString];
    
    // First try exact match
    for (NSString *key in tagColors) {
        if ([lowercaseTag isEqualToString:key]) {
            return tagColors[key];
        }
    }
    
    // Then try contains matching
    for (NSString *key in tagColors.allKeys) {
        if ([lowercaseTag containsString:key] || [key containsString:lowercaseTag]) {
            return tagColors[key];
        }
    }
    
    // Calculate a unique color based on the tag string (for unknown tags)
    NSUInteger hash = 0;
    for (NSUInteger i = 0; i < tag.length; i++) {
        NSUInteger character = [tag characterAtIndex:i];
        hash = ((hash << 5) - hash) + character;
    }
    
    // Use the hash to create a repeatable color with good saturation and brightness
    CGFloat hue = (hash % 256) / 256.0;
    return [UIColor colorWithHue:hue saturation:0.75 brightness:0.85 alpha:1.0];
}

// Helper method to capitalize first letter of each word in a tag
- (NSString *)formatTagName:(NSString *)tagName {
    if (tagName.length == 0) return @"";
    
    NSString *trimmedTag = [tagName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    
    NSMutableString *formattedTag = [NSMutableString string];
    NSArray *words = [trimmedTag componentsSeparatedByString:@" "];
    
    for (NSUInteger i = 0; i < words.count; i++) {
        NSString *word = words[i];
        if (word.length > 0) {
            // Capitalize first letter, keep rest lowercase
            NSString *firstLetter = [[word substringToIndex:1] uppercaseString];
            NSString *restOfWord = word.length > 1 ? [[word substringFromIndex:1] lowercaseString] : @"";
            [formattedTag appendString:firstLetter];
            [formattedTag appendString:restOfWord];
            
            // Add space if not the last word
            if (i < words.count - 1) {
                [formattedTag appendString:@" "];
            }
        }
    }
    
    return formattedTag;
}

// Improved tag handling with better caching and visual design
- (void)setTags:(NSArray<NSString *> *)tags {
    // Clear existing tags first
    for (UIView *tagView in self.tagViews) {
        [tagView removeFromSuperview];
    }
    [self.tagViews removeAllObjects];
    
    if (!tags || tags.count == 0) {
        return;
    }
    
    // Create a horizontal stack to hold tags
    CGFloat xOffset = 0;
    CGFloat tagHeight = 24; // Slightly taller for better readability
    CGFloat tagSpacing = 8;
    
    // Remove duplicates while preserving order
    NSMutableArray *uniqueTags = [NSMutableArray array];
    NSMutableSet *seenTags = [NSMutableSet set];
    
    for (NSString *tag in tags) {
        if (![seenTags containsObject:tag]) {
            [seenTags addObject:tag];
            [uniqueTags addObject:tag];
        }
    }
    
    // Limit to a reasonable number of tags
    NSInteger maxTags = 5;
    NSArray *displayTags = uniqueTags.count > maxTags ? 
                          [uniqueTags subarrayWithRange:NSMakeRange(0, maxTags)] : 
                          uniqueTags;
    
    // Use a measurement cache to avoid recalculating text sizes
    static NSCache *tagSizeCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tagSizeCache = [[NSCache alloc] init];
        tagSizeCache.countLimit = 100;
    });
    
    for (NSString *tag in displayTags) {
        // Skip empty tags
        if (!tag || tag.length == 0) continue;
        
        // Format tag text with proper capitalization
        NSString *formattedTag = [self formatTagName:tag];
        
        // Create tag container view with improved styling
        UIView *tagView = [[UIView alloc] init];
        tagView.backgroundColor = [self colorForTag:tag];
        tagView.layer.cornerRadius = tagHeight / 2;
        tagView.layer.masksToBounds = YES;
        
        // Add subtle shadow for depth
        tagView.layer.shadowColor = [UIColor blackColor].CGColor;
        tagView.layer.shadowOffset = CGSizeMake(0, 1);
        tagView.layer.shadowOpacity = 0.1;
        tagView.layer.shadowRadius = 1;
        
        [self.tagsScrollView addSubview:tagView];
        [self.tagViews addObject:tagView];
        
        // Create tag label with improved typography
        UILabel *tagLabel = [[UILabel alloc] init];
        tagLabel.text = formattedTag;
        tagLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        tagLabel.textColor = [UIColor whiteColor];
        tagLabel.translatesAutoresizingMaskIntoConstraints = NO;
        
        // Important: Set proper label properties to prevent truncation
        tagLabel.lineBreakMode = NSLineBreakByWordWrapping;
        tagLabel.numberOfLines = 1;
        
        [tagView addSubview:tagLabel];
        
        // Check cache for text size or calculate if needed
        NSString *cacheKey = [NSString stringWithFormat:@"%@-%@", formattedTag, NSStringFromCGSize(CGSizeMake(CGFLOAT_MAX, tagHeight))];
        NSValue *cachedSizeValue = [tagSizeCache objectForKey:cacheKey];
        CGSize textSize;
        
        if (cachedSizeValue) {
            textSize = [cachedSizeValue CGSizeValue];
        } else {
            // Use a more generous size calculation to ensure full text is visible
            textSize = [formattedTag boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, tagHeight)
                                                  options:NSStringDrawingUsesLineFragmentOrigin
                                               attributes:@{NSFontAttributeName: tagLabel.font}
                                                  context:nil].size;
            [tagSizeCache setObject:[NSValue valueWithCGSize:textSize] forKey:cacheKey];
        }
        
        // Increase padding to ensure the text isn't cut off
        CGFloat tagWidth = textSize.width + 28; // More padding to ensure full text visibility
        tagView.frame = CGRectMake(xOffset, 0, tagWidth, tagHeight);
        
        // Position label centered in tag
        [NSLayoutConstraint activateConstraints:@[
            [tagLabel.centerXAnchor constraintEqualToAnchor:tagView.centerXAnchor],
            [tagLabel.centerYAnchor constraintEqualToAnchor:tagView.centerYAnchor],
            // Add width constraint to ensure label doesn't exceed tag width
            [tagLabel.widthAnchor constraintLessThanOrEqualToAnchor:tagView.widthAnchor constant:-8]
        ]];
        
        // Update offset for next tag
        xOffset += tagWidth + tagSpacing;
    }
    
    // If we limited the tags, add a +X more indicator with improved styling
    if (uniqueTags.count > maxTags) {
        NSString *moreText = [NSString stringWithFormat:@"+%lu more", (unsigned long)(uniqueTags.count - maxTags)];
        
        UIView *moreView = [[UIView alloc] init];
        moreView.backgroundColor = [UIColor systemGrayColor];
        moreView.layer.cornerRadius = tagHeight / 2;
        
        // Add subtle gradient for better visual appeal
        CAGradientLayer *gradient = [CAGradientLayer layer];
        gradient.frame = CGRectMake(0, 0, 100, tagHeight); // Width will be adjusted later
        gradient.colors = @[(id)[UIColor systemGrayColor].CGColor, (id)[[UIColor systemGrayColor] colorWithAlphaComponent:0.8].CGColor];
        gradient.startPoint = CGPointMake(0.0, 0.5);
        gradient.endPoint = CGPointMake(1.0, 0.5);
        gradient.cornerRadius = tagHeight / 2;
        [moreView.layer insertSublayer:gradient atIndex:0];
        
        [self.tagsScrollView addSubview:moreView];
        [self.tagViews addObject:moreView];
        
        UILabel *moreLabel = [[UILabel alloc] init];
        moreLabel.text = moreText;
        moreLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        moreLabel.textColor = [UIColor whiteColor];
        moreLabel.translatesAutoresizingMaskIntoConstraints = NO;
        moreLabel.textAlignment = NSTextAlignmentCenter;
        [moreView addSubview:moreLabel];
        
        // Check cache for text size or calculate
        NSString *moreCacheKey = [NSString stringWithFormat:@"more-%lu", (unsigned long)(uniqueTags.count - maxTags)];
        NSValue *cachedMoreSize = [tagSizeCache objectForKey:moreCacheKey];
        CGSize moreTextSize;
        
        if (cachedMoreSize) {
            moreTextSize = [cachedMoreSize CGSizeValue];
        } else {
            moreTextSize = [moreText boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, tagHeight)
                                                  options:NSStringDrawingUsesLineFragmentOrigin
                                               attributes:@{NSFontAttributeName: moreLabel.font}
                                                  context:nil].size;
            [tagSizeCache setObject:[NSValue valueWithCGSize:moreTextSize] forKey:moreCacheKey];
        }
        
        // Ensure the "more" indicator has enough space
        CGFloat moreWidth = moreTextSize.width + 24; // More padding for readability
        moreView.frame = CGRectMake(xOffset, 0, moreWidth, tagHeight);
        
        // Update gradient frame to match the actual width
        gradient.frame = CGRectMake(0, 0, moreWidth, tagHeight);
        
        [NSLayoutConstraint activateConstraints:@[
            [moreLabel.centerXAnchor constraintEqualToAnchor:moreView.centerXAnchor],
            [moreLabel.centerYAnchor constraintEqualToAnchor:moreView.centerYAnchor],
            [moreLabel.widthAnchor constraintLessThanOrEqualToAnchor:moreView.widthAnchor constant:-4]
        ]];
        
        xOffset += moreWidth + tagSpacing;
    }
    
    // Set content size of scroll view
    self.tagsScrollView.contentSize = CGSizeMake(xOffset, tagHeight);
}

// Override to improve cell highlighting
- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated {
    [super setHighlighted:highlighted animated:animated];
    
    if (animated) {
        [UIView animateWithDuration:0.2 animations:^{
            self.containerView.backgroundColor = highlighted ? 
                [UIColor tertiarySystemBackgroundColor] : [UIColor secondarySystemBackgroundColor];
            self.containerView.transform = highlighted ? 
                CGAffineTransformMakeScale(0.98, 0.98) : CGAffineTransformIdentity;
        }];
    } else {
        self.containerView.backgroundColor = highlighted ? 
            [UIColor tertiarySystemBackgroundColor] : [UIColor secondarySystemBackgroundColor];
        self.containerView.transform = highlighted ? 
            CGAffineTransformMakeScale(0.98, 0.98) : CGAffineTransformIdentity;
    }
}

// Override to improve cell selection
- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
    
    if (animated) {
        [UIView animateWithDuration:0.2 animations:^{
            self.containerView.backgroundColor = selected ? 
                [UIColor tertiarySystemBackgroundColor] : [UIColor secondarySystemBackgroundColor];
            self.containerView.transform = selected ? 
                CGAffineTransformMakeScale(0.98, 0.98) : CGAffineTransformIdentity;
        }];
    } else {
        self.containerView.backgroundColor = selected ? 
            [UIColor tertiarySystemBackgroundColor] : [UIColor secondarySystemBackgroundColor];
        self.containerView.transform = selected ? 
            CGAffineTransformMakeScale(0.98, 0.98) : CGAffineTransformIdentity;
    }
}

@end

#pragma mark - Section Header View Definition

// Improved header view for modpack categories
@interface ModpackCategoryHeaderView : UITableViewHeaderFooterView
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIImageView *iconImageView;
@property (nonatomic, strong) UIImageView *chevronImageView;
@property (nonatomic, strong) UIButton *expandCollapseButton;
@property (nonatomic, assign) BOOL isExpanded;
@property (nonatomic, strong) UIVisualEffectView *blurEffect;
@end

@implementation ModpackCategoryHeaderView

- (instancetype)initWithReuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithReuseIdentifier:reuseIdentifier];
    if (self) {
        // Apply a blur effect for a modern look
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular];
        self.blurEffect = [[UIVisualEffectView alloc] initWithEffect:blur];
        self.blurEffect.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.blurEffect];
        
        // Create a container view with improved styling
        self.containerView = [[UIView alloc] init];
        self.containerView.translatesAutoresizingMaskIntoConstraints = NO;
        self.containerView.backgroundColor = [UIColor clearColor];
        [self.contentView addSubview:self.containerView];
        
        // Add an icon for visual categorization
        self.iconImageView = [[UIImageView alloc] init];
        self.iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconImageView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconImageView.tintColor = [UIColor labelColor];
        [self.containerView addSubview:self.iconImageView];
        
        // Title label - larger, bolder font with dynamic type support
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
        self.titleLabel.adjustsFontForContentSizeCategory = YES;
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.containerView addSubview:self.titleLabel];
        
        // Chevron indicator - animated rotation on expand/collapse
        self.chevronImageView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down"]];
        self.chevronImageView.tintColor = [UIColor systemGrayColor];
        self.chevronImageView.translatesAutoresizingMaskIntoConstraints = NO;
        self.chevronImageView.contentMode = UIViewContentModeScaleAspectFit;
        [self.containerView addSubview:self.chevronImageView];
        
        // Button covering the entire header - for expansion/collapse
        self.expandCollapseButton = [UIButton buttonWithType:UIButtonTypeSystem];
        self.expandCollapseButton.translatesAutoresizingMaskIntoConstraints = NO;
        self.expandCollapseButton.backgroundColor = [UIColor clearColor];
        [self.containerView addSubview:self.expandCollapseButton];
        
        // Blur effect constraints (cover the entire view)
        [NSLayoutConstraint activateConstraints:@[
            [self.blurEffect.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [self.blurEffect.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [self.blurEffect.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [self.blurEffect.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor]
        ]];
        
        // Container view constraints (full size with padding)
        [NSLayoutConstraint activateConstraints:@[
            [self.containerView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [self.containerView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [self.containerView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [self.containerView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor]
        ]];
        
        // Icon constraints
        [NSLayoutConstraint activateConstraints:@[
            [self.iconImageView.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor constant:16],
            [self.iconImageView.centerYAnchor constraintEqualToAnchor:self.containerView.centerYAnchor],
            [self.iconImageView.widthAnchor constraintEqualToConstant:24],
            [self.iconImageView.heightAnchor constraintEqualToConstant:24]
        ]];
        
        // Title label constraints - positioned after icon
        [NSLayoutConstraint activateConstraints:@[
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconImageView.trailingAnchor constant:12],
            [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.containerView.centerYAnchor],
            [self.titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.chevronImageView.leadingAnchor constant:-16]
        ]];
        
        // Chevron constraints - at trailing edge
        [NSLayoutConstraint activateConstraints:@[
            [self.chevronImageView.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor constant:-16],
            [self.chevronImageView.centerYAnchor constraintEqualToAnchor:self.containerView.centerYAnchor],
            [self.chevronImageView.widthAnchor constraintEqualToConstant:22],
            [self.chevronImageView.heightAnchor constraintEqualToConstant:22]
        ]];
        
        // Button constraints (covers the whole area)
        [NSLayoutConstraint activateConstraints:@[
            [self.expandCollapseButton.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor],
            [self.expandCollapseButton.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor],
            [self.expandCollapseButton.topAnchor constraintEqualToAnchor:self.containerView.topAnchor],
            [self.expandCollapseButton.bottomAnchor constraintEqualToAnchor:self.containerView.bottomAnchor]
        ]];
        
        // Apply haptic feedback to button for better interaction feel
        if (@available(iOS 14.0, *)) {
            UIPointerInteraction *pointerInteraction = [[UIPointerInteraction alloc] initWithDelegate:nil];
            [self.expandCollapseButton addInteraction:pointerInteraction];
        }
    }
    return self;
}

- (void)setIsExpanded:(BOOL)isExpanded {
    _isExpanded = isExpanded;
    
    // Set the appropriate icon based on the category
    if ([self.titleLabel.text containsString:@"Magic"]) {
        self.iconImageView.image = [UIImage systemImageNamed:@"sparkles"];
    } else if ([self.titleLabel.text containsString:@"Tech"]) {
        self.iconImageView.image = [UIImage systemImageNamed:@"gear"];
    } else if ([self.titleLabel.text containsString:@"Adventure"]) {
        self.iconImageView.image = [UIImage systemImageNamed:@"map"];
    } else if ([self.titleLabel.text containsString:@"Featured"]) {
        self.iconImageView.image = [UIImage systemImageNamed:@"star.fill"];
        self.iconImageView.tintColor = [UIColor systemYellowColor];
    } else {
        self.iconImageView.image = [UIImage systemImageNamed:@"cube.box"];
    }
    
    // Animate chevron rotation with spring animation for more natural feel
    [UIView animateWithDuration:0.5 
                          delay:0 
         usingSpringWithDamping:0.7 
          initialSpringVelocity:0.5 
                        options:UIViewAnimationOptionAllowUserInteraction 
                     animations:^{
                         self.chevronImageView.transform = isExpanded ? 
                            CGAffineTransformMakeRotation(M_PI) : CGAffineTransformIdentity;
                     } completion:nil];
    
    // Animate container for additional feedback
    [UIView animateWithDuration:0.3 animations:^{
        self.containerView.backgroundColor = isExpanded ? 
            [[UIColor systemBlueColor] colorWithAlphaComponent:0.1] : [UIColor clearColor];
    }];
}

@end

// Loading shimmer cell for better loading states
@interface ShimmerCell : UITableViewCell
@property (nonatomic, strong) CAGradientLayer *gradientLayer;
@property (nonatomic, strong) NSArray<UIView *> *shimmerViews;
@property (nonatomic, strong) NSTimer *animationTimer;
@end

@implementation ShimmerCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [UIColor clearColor];
        
        // Container for shimmer effect
        UIView *containerView = [[UIView alloc] init];
        containerView.translatesAutoresizingMaskIntoConstraints = NO;
        containerView.backgroundColor = [UIColor secondarySystemBackgroundColor];
        containerView.layer.cornerRadius = 12;
        [self.contentView addSubview:containerView];
        
        [NSLayoutConstraint activateConstraints:@[
            [containerView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],
            [containerView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8],
            [containerView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [containerView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16]
        ]];
        
        // Create shimmer views (placeholder for content)
        NSMutableArray *shimmerViews = [NSMutableArray array];
        
        // Icon placeholder
        UIView *iconView = [[UIView alloc] init];
        iconView.translatesAutoresizingMaskIntoConstraints = NO;
        iconView.backgroundColor = [UIColor systemGray5Color];
        iconView.layer.cornerRadius = 24;
        [containerView addSubview:iconView];
        [shimmerViews addObject:iconView];
        
        // Title placeholder
        UIView *titleView = [[UIView alloc] init];
        titleView.translatesAutoresizingMaskIntoConstraints = NO;
        titleView.backgroundColor = [UIColor systemGray5Color];
        titleView.layer.cornerRadius = 4;
        [containerView addSubview:titleView];
        [shimmerViews addObject:titleView];
        
        // Subtitle placeholder
        UIView *subtitleView = [[UIView alloc] init];
        subtitleView.translatesAutoresizingMaskIntoConstraints = NO;
        subtitleView.backgroundColor = [UIColor systemGray5Color];
        subtitleView.layer.cornerRadius = 4;
        [containerView addSubview:subtitleView];
        [shimmerViews addObject:subtitleView];
        
        // Tags placeholder
        UIView *tagsView = [[UIView alloc] init];
        tagsView.translatesAutoresizingMaskIntoConstraints = NO;
        tagsView.backgroundColor = [UIColor systemGray5Color];
        tagsView.layer.cornerRadius = 4;
        [containerView addSubview:tagsView];
        [shimmerViews addObject:tagsView];
        
        // Layout constraints
        [NSLayoutConstraint activateConstraints:@[
            // Icon
            [iconView.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor constant:12],
            [iconView.centerYAnchor constraintEqualToAnchor:containerView.centerYAnchor],
            [iconView.widthAnchor constraintEqualToConstant:48],
            [iconView.heightAnchor constraintEqualToConstant:48],
            
            // Title
            [titleView.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:16],
            [titleView.topAnchor constraintEqualToAnchor:containerView.topAnchor constant:16],
            [titleView.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-50],
            [titleView.heightAnchor constraintEqualToConstant:18],
            
            // Subtitle
            [subtitleView.leadingAnchor constraintEqualToAnchor:titleView.leadingAnchor],
            [subtitleView.topAnchor constraintEqualToAnchor:titleView.bottomAnchor constant:10],
            [subtitleView.widthAnchor constraintEqualToAnchor:titleView.widthAnchor multiplier:0.75],
            [subtitleView.heightAnchor constraintEqualToConstant:14],
            
            // Tags
            [tagsView.leadingAnchor constraintEqualToAnchor:titleView.leadingAnchor],
            [tagsView.topAnchor constraintEqualToAnchor:subtitleView.bottomAnchor constant:10],
            [tagsView.widthAnchor constraintEqualToAnchor:titleView.widthAnchor multiplier:0.5],
            [tagsView.heightAnchor constraintEqualToConstant:24],
        ]];
        
        self.shimmerViews = shimmerViews;
        
        // Set up gradient for shimmer effect
        self.gradientLayer = [CAGradientLayer layer];
        self.gradientLayer.colors = @[
            (id)[[UIColor clearColor] CGColor],
            (id)[[UIColor whiteColor] colorWithAlphaComponent:0.2].CGColor,
            (id)[[UIColor clearColor] CGColor]
        ];
        self.gradientLayer.locations = @[@0.35, @0.5, @0.65];
        self.gradientLayer.startPoint = CGPointMake(0, 0.5);
        self.gradientLayer.endPoint = CGPointMake(1, 0.5);
        containerView.layer.mask = nil;
        [containerView.layer addSublayer:self.gradientLayer];
        
        // Start shimmer animation
        self.animationTimer = [NSTimer scheduledTimerWithTimeInterval:0.01 target:self selector:@selector(updateShimmerAnimation) userInfo:nil repeats:YES];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    
    // Update gradient frame
    self.gradientLayer.frame = CGRectMake(-self.bounds.size.width, 0, self.bounds.size.width * 3, self.bounds.size.height);
}

- (void)updateShimmerAnimation {
    // Create shimmer animation by moving the gradient
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"position.x"];
    animation.fromValue = @(-self.bounds.size.width);
    animation.toValue = @(self.bounds.size.width * 2);
    animation.duration = 1.5;
    animation.repeatCount = HUGE_VALF;
    [self.gradientLayer addAnimation:animation forKey:@"shimmerAnimation"];
    
    // Stop the timer as the animation is now running on its own
    [self.animationTimer invalidate];
    self.animationTimer = nil;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    
    // Re-start animation
    if (!self.animationTimer.isValid) {
        self.animationTimer = [NSTimer scheduledTimerWithTimeInterval:0.01 target:self selector:@selector(updateShimmerAnimation) userInfo:nil repeats:YES];
    }
}

- (void)dealloc {
    [self.animationTimer invalidate];
    self.animationTimer = nil;
}

@end

#pragma mark - View Controller Implementation

@interface ModpackInstallViewController()<UIContextMenuInteractionDelegate, UIPopoverPresentationControllerDelegate, UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, strong) NSString *searchText;
@property(nonatomic, strong) UIMenu *currentMenu;
@property(nonatomic, strong) ModrinthAPI *modrinth;
@property(atomic) AFURLSessionManager *afManager;
@property(nonatomic, strong) WFWorkflowProgressView *progressView;
@property(nonatomic, strong) NSMutableDictionary *filters;
@property(nonatomic, strong) NSMutableSet *activeTagFilters;

// Data structure for organized sections
@property(nonatomic, strong) NSMutableArray<NSString *> *categories;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *visibilityList;
@property(nonatomic, strong) NSMutableArray<NSMutableArray *> *organizedModpacks;
@property(nonatomic, strong) NSMutableArray<NSMutableArray *> *filteredModpacks;

// Unified search results array (for search mode)
@property(nonatomic, strong) NSMutableArray *unifiedSearchResults;
@property(nonatomic, assign) BOOL isSearchActive;

// Tracking for current operations
@property(nonatomic, strong) NSIndexPath *currentDownloadIndexPath;
@property(atomic, assign) BOOL isDataLoading;
@property(nonatomic, strong) NSLock *dataLock;

// Infinite scroll support
@property(nonatomic, assign) BOOL isLoadingMoreResults;
@property(nonatomic, assign) BOOL hasMoreResults;

// UI elements for more modern experience
@property(nonatomic, strong) UISegmentedControl *segmentedControl;
@property(nonatomic, strong) UIRefreshControl *modernRefreshControl;
@property(nonatomic, strong) UICollectionView *tagCollectionView;
@property(nonatomic, strong) NSArray<NSString *> *popularTags;
@property(nonatomic, strong) UIView *emptyStateView;
@property(nonatomic, strong) UILabel *emptyStateLabel;
@property(nonatomic, strong) UIImageView *emptyStateImageView;
@property(nonatomic, strong) UIButton *emptyStateButton;
@end

@implementation ModpackInstallViewController

#pragma mark - Initialization Methods

- (instancetype)init {
    return [self initWithStyle:UITableViewStyleGrouped];
}

- (instancetype)initWithStyle:(UITableViewStyle)style {
    self = [super initWithStyle:UITableViewStyleGrouped];
    return self;
}

#pragma mark - Lifecycle Methods

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Set modern appearance
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    
    // Configure table view appearance
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0;
    }
    
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = [UIColor systemBackgroundColor];
    
    // Configure proper insets for navigation and search
    self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    
    // Ensure the table view doesn't scroll under the navigation bar
    self.extendedLayoutIncludesOpaqueBars = NO;
    self.edgesForExtendedLayout = UIRectEdgeNone;
    
    // Register custom cell and header view
    [self.tableView registerClass:[ModpackVersionCell class] forCellReuseIdentifier:@"ModpackVersionCell"];
    [self.tableView registerClass:[ModpackCategoryHeaderView class] forHeaderFooterViewReuseIdentifier:@"ModpackCategoryHeader"];
    [self.tableView registerClass:[ShimmerCell class] forCellReuseIdentifier:@"ShimmerCell"];
    
    // Title for the view controller
    self.title = localize(@"Modpacks", nil);
    
    // Initialize tag filter set
    self.activeTagFilters = [NSMutableSet new];
    
    // Initialize unified search results array
    self.unifiedSearchResults = [NSMutableArray new];
    self.isSearchActive = NO;
    self.hasMoreResults = YES;
    
    // Setup popular tags for quick filtering
    self.popularTags = @[
        @"Magic", @"Tech", @"Adventure", @"Quests", @"Fabric", 
        @"Forge", @"Multiplayer", @"Lightweight", @"Kitchen Sink", @"Skyblock"
    ];
    
    // Setup tag collection view for horizontal scrolling tags
    [self setupTagCollectionView];
    
    // Setup category filter - segmented control with modern styling
    [self setupSegmentedControl];
    
    // Setup search controller with improved styling
    [self setupSearchController];
    
    // Setup refresh control with modern appearance
    [self setupRefreshControl];
    
    // Setup empty state view
    [self setupEmptyStateView];
    
    // Add proper KVO monitoring of search active state
    [self.searchController addObserver:self
                            forKeyPath:@"active"
                               options:NSKeyValueObservingOptionNew
                               context:NULL];
    
    // Load WorkflowProgressView for download progress
    dlopen("/System/Library/PrivateFrameworks/WorkflowUIServices.framework/WorkflowUIServices", RTLD_GLOBAL);
    self.progressView = [[NSClassFromString(@"WFWorkflowProgressView") alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    self.progressView.resolvedTintColor = self.view.tintColor;
    [self.progressView addTarget:self action:@selector(actionCancelDownload) forControlEvents:UIControlEventTouchUpInside];
    
    // Add only close button to navigation (removed tag filter button)
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] 
                                   initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                   target:self 
                                   action:@selector(actionClose)];
    
    self.navigationItem.rightBarButtonItems = @[closeButton];
    
    // Initialize data structures with thread safety
    self.categories = [NSMutableArray new];
    self.visibilityList = [NSMutableArray new];
    self.organizedModpacks = [NSMutableArray new];
    self.filteredModpacks = [NSMutableArray new];
    self.isDataLoading = NO;
    self.dataLock = [[NSLock alloc] init];

    // Initialize modrinth API
    self.modrinth = [ModrinthAPI new];

    // Setup default filters
    self.filters = @{
        @"isModpack": @(YES),
        @"name": @"",
        @"sortMethod": @"relevance" // Default sort method
    }.mutableCopy;

     // Load initial data asynchronously with a delay to allow UI to appear first
    dispatch_async(dispatch_get_main_queue(), ^{
        // Show initial loading state
        [self switchToLoadingState];
    
        // Delay network request until view is fully displayed
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self updateSearchResults];
        });
    });
}

- (void)setupSegmentedControl {
    // Create modern segmented control with improved styling
    self.segmentedControl = [[UISegmentedControl alloc] initWithItems:@[
        localize(@"Popular", nil),
        localize(@"New", nil),
        localize(@"Updated", nil)
    ]];
    
    // Apply modern styling
    self.segmentedControl.selectedSegmentIndex = 0;
    
    // Add shadow for depth
    self.segmentedControl.layer.shadowColor = [UIColor blackColor].CGColor;
    self.segmentedControl.layer.shadowOffset = CGSizeMake(0, 1);
    self.segmentedControl.layer.shadowOpacity = 0.1;
    self.segmentedControl.layer.shadowRadius = 2;
    
    [self.segmentedControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    
    // Set as navigation title view for better positioning
    self.navigationItem.titleView = self.segmentedControl;
}

- (void)setupSearchController {
    // Create search controller with modern styling
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    
    // More descriptive placeholder
    self.searchController.searchBar.placeholder = localize(@"Search for modpacks...", nil);
    
    // Add scope buttons for better filtering
    self.searchController.searchBar.scopeButtonTitles = @[
        localize(@"All", nil),
    ];
    
    // Customize search bar appearance
    self.searchController.searchBar.tintColor = [UIColor systemBlueColor];
    
    // Set search controller in navigation
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

- (void)setupRefreshControl {
    // Create modern refresh control with improved styling
    self.modernRefreshControl = [[UIRefreshControl alloc] init];
    
    // Add custom label for more informative feedback
    UILabel *refreshLabel = [[UILabel alloc] init];
    refreshLabel.textAlignment = NSTextAlignmentCenter;
    refreshLabel.textColor = [UIColor secondaryLabelColor];
    refreshLabel.font = [UIFont systemFontOfSize:12];
    refreshLabel.text = localize(@"Pull to refresh modpacks", nil);
    [self.modernRefreshControl addSubview:refreshLabel];
    
    // Center label
    refreshLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [refreshLabel.centerXAnchor constraintEqualToAnchor:self.modernRefreshControl.centerXAnchor],
        [refreshLabel.bottomAnchor constraintEqualToAnchor:self.modernRefreshControl.bottomAnchor constant:-10]
    ]];
    
    // Add action to refresh control
    [self.modernRefreshControl addTarget:self action:@selector(refreshModpacks) forControlEvents:UIControlEventValueChanged];
    [self.tableView addSubview:self.modernRefreshControl];
}

- (void)setupTagCollectionView {
    // Create a collection view layout
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.minimumInteritemSpacing = 8;
    layout.minimumLineSpacing = 8;
    layout.sectionInset = UIEdgeInsetsMake(8, 16, 8, 16);
    
    // Create the collection view
    self.tagCollectionView = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.tagCollectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tagCollectionView.backgroundColor = [UIColor clearColor];
    self.tagCollectionView.showsHorizontalScrollIndicator = NO;
    self.tagCollectionView.delegate = self;
    self.tagCollectionView.dataSource = self;
    
    // Register cell for collection view
    [self.tagCollectionView registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"TagCell"];
    
    // Create header view to contain the collection view
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 60)];
    [headerView addSubview:self.tagCollectionView];
    
    // Add constraints
    [NSLayoutConstraint activateConstraints:@[
        [self.tagCollectionView.leadingAnchor constraintEqualToAnchor:headerView.leadingAnchor],
        [self.tagCollectionView.trailingAnchor constraintEqualToAnchor:headerView.trailingAnchor],
        [self.tagCollectionView.topAnchor constraintEqualToAnchor:headerView.topAnchor],
        [self.tagCollectionView.bottomAnchor constraintEqualToAnchor:headerView.bottomAnchor]
    ]];
    
    // Set as table header view
    self.tableView.tableHeaderView = headerView;
}

- (void)setupEmptyStateView {
    // Create empty state view
    self.emptyStateView = [[UIView alloc] initWithFrame:CGRectZero];
    self.emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateView.hidden = YES;
    [self.view addSubview:self.emptyStateView];
    
    // Add image view for visual appeal
    self.emptyStateImageView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"cube.box"]];
    self.emptyStateImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.emptyStateImageView.tintColor = [UIColor secondaryLabelColor];
    [self.emptyStateView addSubview:self.emptyStateImageView];
    
    // Add label for descriptive text
    self.emptyStateLabel = [[UILabel alloc] init];
    self.emptyStateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyStateLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.emptyStateLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyStateLabel.numberOfLines = 0;
    self.emptyStateLabel.text = localize(@"No modpacks found. Try adjusting your search criteria.", nil);
    [self.emptyStateView addSubview:self.emptyStateLabel];
    
    // Add button for retry action
    self.emptyStateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.emptyStateButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.emptyStateButton setTitle:localize(@"Try Again", nil) forState:UIControlStateNormal];
    [self.emptyStateButton addTarget:self action:@selector(refreshModpacks) forControlEvents:UIControlEventTouchUpInside];
    [self.emptyStateView addSubview:self.emptyStateButton];
    
    // Constraints for empty state view
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyStateView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyStateView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyStateView.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.8],
        
        [self.emptyStateImageView.topAnchor constraintEqualToAnchor:self.emptyStateView.topAnchor],
        [self.emptyStateImageView.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [self.emptyStateImageView.widthAnchor constraintEqualToConstant:80],
        [self.emptyStateImageView.heightAnchor constraintEqualToConstant:80],
        
        [self.emptyStateLabel.topAnchor constraintEqualToAnchor:self.emptyStateImageView.bottomAnchor constant:16],
        [self.emptyStateLabel.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor],
        [self.emptyStateLabel.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor],
        
        [self.emptyStateButton.topAnchor constraintEqualToAnchor:self.emptyStateLabel.bottomAnchor constant:24],
        [self.emptyStateButton.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [self.emptyStateButton.bottomAnchor constraintEqualToAnchor:self.emptyStateView.bottomAnchor]
    ]];
}

- (void)dealloc {
    // Remove KVO observer
    [self.searchController removeObserver:self forKeyPath:@"active"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (object == self.searchController && [keyPath isEqualToString:@"active"]) {
        BOOL isActive = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
        
        // Only update if the state has changed
        if (isActive != self.isSearchActive) {
            self.isSearchActive = isActive;
            
            // Reset any pagination flags when toggling search
            self.isLoadingMoreResults = NO;
            
            if (isActive) {
                // Hide tag collection view in search mode
                self.tableView.tableHeaderView.hidden = YES;
                
                // When search becomes active, create unified search results
                [self updateUnifiedSearchResults];
            } else {
                // Show tag collection view in normal mode
                self.tableView.tableHeaderView.hidden = NO;
            }
            
            // Always reload the table view to ensure consistency
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
            });
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - Collection View Delegate & Data Source

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return self.popularTags.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"TagCell" forIndexPath:indexPath];
    
    // Remove any existing tag labels
    for (UIView *subview in cell.contentView.subviews) {
        [subview removeFromSuperview];
    }
    
    // Get tag and trim any whitespace
    NSString *tagText = self.popularTags[indexPath.item];
    tagText = [tagText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    
    // Create tag label
    UILabel *tagLabel = [[UILabel alloc] init];
    tagLabel.translatesAutoresizingMaskIntoConstraints = NO;
    tagLabel.text = tagText;
    tagLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    
    // Check if this tag is active
    BOOL isActive = [self.activeTagFilters containsObject:[tagText lowercaseString]];
    
    // Container view with rounded corners
    UIView *containerView = [[UIView alloc] init];
    containerView.translatesAutoresizingMaskIntoConstraints = NO;
    containerView.layer.cornerRadius = 16;
    containerView.clipsToBounds = YES;
    
    // Set colors based on selection state
    if (isActive) {
        containerView.backgroundColor = [UIColor systemBlueColor];
        tagLabel.textColor = [UIColor whiteColor];
        
        // Add checkmark for active tags
        UIImageView *checkmark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
        checkmark.translatesAutoresizingMaskIntoConstraints = NO;
        checkmark.tintColor = [UIColor whiteColor];
        [containerView addSubview:checkmark];
        
        [NSLayoutConstraint activateConstraints:@[
            [checkmark.trailingAnchor constraintEqualToAnchor:containerView.trailingAnchor constant:-8],
            [checkmark.centerYAnchor constraintEqualToAnchor:containerView.centerYAnchor],
            [checkmark.widthAnchor constraintEqualToConstant:16],
            [checkmark.heightAnchor constraintEqualToConstant:16]
        ]];
    } else {
        containerView.backgroundColor = [UIColor tertiarySystemBackgroundColor];
        tagLabel.textColor = [UIColor labelColor];
    }
    
    // Add container to cell
    [cell.contentView addSubview:containerView];
    [containerView addSubview:tagLabel];
    
    // Constraints for container
    [NSLayoutConstraint activateConstraints:@[
        [containerView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor],
        [containerView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor],
        [containerView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor],
        [containerView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor]
    ]];
    
    // Constraints for label - adjusted to show full text
    [NSLayoutConstraint activateConstraints:@[
        [tagLabel.leadingAnchor constraintEqualToAnchor:containerView.leadingAnchor constant:12],
        [tagLabel.centerYAnchor constraintEqualToAnchor:containerView.centerYAnchor],
        [tagLabel.trailingAnchor constraintLessThanOrEqualToAnchor:containerView.trailingAnchor constant:isActive ? -28 : -12]
    ]];
    
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    // Calculate size based on text width
    NSString *tagText = self.popularTags[indexPath.item];
    UIFont *font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    
    CGSize textSize = [tagText boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, 32)
                                           options:NSStringDrawingUsesLineFragmentOrigin
                                        attributes:@{NSFontAttributeName: font}
                                           context:nil].size;
    
    // Add more padding to ensure full text visibility
    BOOL isActive = [self.activeTagFilters containsObject:[self.popularTags[indexPath.item] lowercaseString]];
    CGFloat width = textSize.width + (isActive ? 56 : 32); // More space for full text visibility
    
    return CGSizeMake(width, 32);
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    // Toggle tag selection
    NSString *selectedTag = [self.popularTags[indexPath.item] lowercaseString];
    
    if ([self.activeTagFilters containsObject:selectedTag]) {
        [self.activeTagFilters removeObject:selectedTag];
    } else {
        [self.activeTagFilters addObject:selectedTag];
    }
    
    // Update UI
    [collectionView reloadItemsAtIndexPaths:@[indexPath]];
    [self updateFilterIndicators];
    
    // Update search results
    [self updateUnifiedSearchResults];
    [self.tableView reloadData];
}

#pragma mark - Action Methods

- (BOOL)modpack:(NSDictionary *)modpack matchesSearchText:(NSString *)searchText andTags:(NSSet *)tagFilters {
    // Quick return if no filters are active
    if (searchText.length == 0 && tagFilters.count == 0) {
        return YES;
    }
    
    // Safely extract values with type checking
    NSString *title = [modpack[@"title"] isKindOfClass:[NSString class]] ? modpack[@"title"] : @"";
    NSString *description = [modpack[@"description"] isKindOfClass:[NSString class]] ? modpack[@"description"] : @"";
    
    // Process categories - ensure it's an array
    id categoriesObj = modpack[@"categories"];
    NSArray *categories = [categoriesObj isKindOfClass:[NSArray class]] ? categoriesObj : @[];
    
    // Check tag filters first (faster check)
    if (tagFilters.count > 0) {
        // Default to not matching until we find a matching tag
        BOOL matchesTagFilters = NO;
        
        for (id tagObj in categories) {
            if (![tagObj isKindOfClass:[NSString class]]) continue;
            
            NSString *tag = [(NSString *)tagObj lowercaseString];
            if ([tagFilters containsObject:tag]) {
                matchesTagFilters = YES;
                break;
            }
        }
        
        // If tag filters don't match, exit early
        if (!matchesTagFilters) {
            return NO;
        }
    }
    
    // If no search text, we already passed the tag filter check
    if (searchText.length == 0) {
        return YES;
    }
    
    // Convert to lowercase once for efficiency
    NSString *lowerSearchText = [searchText lowercaseString];
    
    // Check if search text appears in title (most common case)
    if ([[title lowercaseString] containsString:lowerSearchText]) {
        return YES;
    }
    
    // Check description next
    if ([[description lowercaseString] containsString:lowerSearchText]) {
        return YES;
    }
    
    // Finally check tags/categories
    for (id tagObj in categories) {
        if (![tagObj isKindOfClass:[NSString class]]) continue;
        
        NSString *tag = [(NSString *)tagObj lowercaseString];
        if ([tag containsString:lowerSearchText]) {
            return YES;
        }
    }
    
    // If we get here, no match was found
    return NO;
}

- (void)refreshModpacks {
    [self updateSearchResults];
}

- (void)actionCancelDownload {
    // Add haptic feedback for better user experience
    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [generator prepare];
    [generator impactOccurred];
    
    // Reset the current download cell's appearance
    if (self.currentDownloadIndexPath) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:self.currentDownloadIndexPath];
        if (cell) {
            cell.accessoryView = nil;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        self.currentDownloadIndexPath = nil;
    }
    
    [self.afManager invalidateSessionCancelingTasks:YES resetSession:NO];
    
    // Show a toast-style notification instead of a full dialog
    [self showToast:localize(@"Download cancelled", nil)];
}

- (void)showToast:(NSString *)message {
    // Create toast container
    UIView *toastContainer = [[UIView alloc] init];
    toastContainer.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
    toastContainer.layer.cornerRadius = 10;
    toastContainer.translatesAutoresizingMaskIntoConstraints = NO;
    toastContainer.clipsToBounds = YES;
    [self.view addSubview:toastContainer];
    
    // Create toast label
    UILabel *toastLabel = [[UILabel alloc] init];
    toastLabel.text = message;
    toastLabel.textColor = [UIColor whiteColor];
    toastLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    toastLabel.translatesAutoresizingMaskIntoConstraints = NO;
    toastLabel.textAlignment = NSTextAlignmentCenter;
    [toastContainer addSubview:toastLabel];
    
    // Constraints for toast container
    [NSLayoutConstraint activateConstraints:@[
        [toastContainer.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [toastContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20],
        [toastContainer.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor multiplier:0.8],
        [toastContainer.widthAnchor constraintGreaterThanOrEqualToConstant:100]
    ]];
    
    // Constraints for toast label
    [NSLayoutConstraint activateConstraints:@[
        [toastLabel.topAnchor constraintEqualToAnchor:toastContainer.topAnchor constant:8],
        [toastLabel.bottomAnchor constraintEqualToAnchor:toastContainer.bottomAnchor constant:-8],
        [toastLabel.leadingAnchor constraintEqualToAnchor:toastContainer.leadingAnchor constant:16],
        [toastLabel.trailingAnchor constraintEqualToAnchor:toastContainer.trailingAnchor constant:-16]
    ]];
    
    // Animate toast in
    toastContainer.alpha = 0.0;
    [UIView animateWithDuration:0.3 animations:^{
        toastContainer.alpha = 1.0;
    }];
    
    // Animate toast out after delay
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{
            toastContainer.alpha = 0.0;
        } completion:^(BOOL finished) {
            [toastContainer removeFromSuperview];
        }];
    });
}

- (void)actionClose {
    // Add haptic feedback for better user experience
    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [generator prepare];
    [generator impactOccurred];
    
    // Add animation for smoother transition
    [UIView animateWithDuration:0.2 animations:^{
        self.view.alpha = 0.0;
    } completion:^(BOOL finished) {
        [self.navigationController dismissViewControllerAnimated:YES completion:nil];
    }];
}

- (void)segmentChanged:(UISegmentedControl *)segment {
    // Add haptic feedback for better user experience
    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [generator prepare];
    [generator impactOccurred];
    
    // Reset search if active
    if (self.searchController.isActive) {
        [self.searchController dismissViewControllerAnimated:YES completion:nil];
    }
    
    // Clear the current results
    [self.dataLock lock];
    [self.organizedModpacks removeAllObjects];
    [self.filteredModpacks removeAllObjects];
    [self.categories removeAllObjects];
    [self.visibilityList removeAllObjects];
    [self.unifiedSearchResults removeAllObjects];
    [self.dataLock unlock];
    
    // Update filter based on segment
    NSString *sortMethod;
    switch (segment.selectedSegmentIndex) {
        case 1: // New
            sortMethod = @"newest";
            break;
        case 2: // Updated
            sortMethod = @"updated";
            break;
        default: // Popular (default)
            sortMethod = @"relevance";
            break;
    }
    
    // Update the filter
    self.filters[@"sortMethod"] = sortMethod;
    
    // Reset pagination state
    self.hasMoreResults = YES;
    
    // Show loading state
    [self switchToLoadingState];
    
    // Reload data with new filter
    [self updateSearchResults];
}

- (void)showTagFilterMenu:(UIBarButtonItem *)sender {
    // Create a modern filter menu with a visual blur background
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:localize(@"Filter by Tags", nil)
                                                                    message:localize(@"Select tags to filter modpacks", nil)
                                                             preferredStyle:UIAlertControllerStyleActionSheet];
    
    // Create a set of all available tags
    NSMutableSet *allTagsSet = [NSMutableSet new];
    
    // Get all tags from all modpacks - thread safe approach
    [self.dataLock lock];
    // Create a copy of organized modpacks to avoid mutation issues
    NSArray *safeCategoriesArray = [NSArray arrayWithArray:self.organizedModpacks];
    [self.dataLock unlock];
    
    // Get all tags from all modpacks
    for (NSArray *categoryModpacks in safeCategoriesArray) {
        // Skip if not an array
        if (![categoryModpacks isKindOfClass:[NSArray class]]) continue;
        
        for (NSDictionary *modpack in categoryModpacks) {
            // Skip if not a dictionary
            if (![modpack isKindOfClass:[NSDictionary class]]) continue;
            
            NSArray *categories = modpack[@"categories"];
            // Skip if categories is not an array
            if (![categories isKindOfClass:[NSArray class]]) continue;
            
            for (NSString *category in categories) {
                // Skip if not a string
                if (![category isKindOfClass:[NSString class]]) continue;
                
                // Store lowercase version for case-insensitive matching
                [allTagsSet addObject:[category lowercaseString]];
            }
        }
    }
    
    // Format tag names with proper capitalization
    NSMutableDictionary *formattedTagMap = [NSMutableDictionary dictionary];
    for (NSString *tag in allTagsSet) {
        // Use the ModpackVersionCell helper to format tag names consistently
        ModpackVersionCell *dummyCell = [[ModpackVersionCell alloc] init];
        NSString *formattedTag = [dummyCell formatTagName:tag];
        formattedTagMap[tag] = formattedTag;
    }
    
    // Convert to sorted array using formatted names
    NSArray *allTags = [[allTagsSet allObjects] sortedArrayUsingComparator:^NSComparisonResult(NSString *tag1, NSString *tag2) {
        NSString *formattedTag1 = formattedTagMap[tag1];
        NSString *formattedTag2 = formattedTagMap[tag2];
        return [formattedTag1 localizedCaseInsensitiveCompare:formattedTag2];
    }];
    
    // Add actions for each tag
    for (NSString *tag in allTags) {
        // Create a copy of activeTagFilters to avoid any mutation during enumeration
        NSSet *activeTagFiltersCopy = [NSSet setWithSet:self.activeTagFilters];
        BOOL isSelected = [activeTagFiltersCopy containsObject:tag];
        NSString *formattedTag = formattedTagMap[tag];
        NSString *title = isSelected ? [NSString stringWithFormat:@"✓ %@", formattedTag] : formattedTag;
        
        UIAlertAction *action = [UIAlertAction actionWithTitle:title
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction * _Nonnull action) {
            // Toggle tag selection - use main thread for UI updates
            dispatch_async(dispatch_get_main_queue(), ^{
                if (isSelected) {
                    [self.activeTagFilters removeObject:tag];
                } else {
                    [self.activeTagFilters addObject:tag];
                }
                
                // Update collection view to show selected tags
                [self.tagCollectionView reloadData];
                
                // Apply filters without dismissing the menu
                [self updateUnifiedSearchResults];
                [self updateFilterIndicators];
                
                // Show the tag menu again with updated selection state
                [self showTagFilterMenu:sender];
            });
        }];
        
        [alertController addAction:action];
    }
    
    // Add clear filters option
    UIAlertAction *clearAction = [UIAlertAction actionWithTitle:localize(@"Clear All Filters", nil)
                                                         style:UIAlertActionStyleDestructive
                                                       handler:^(UIAlertAction * _Nonnull action) {
        // Add haptic feedback
        UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [generator prepare];
        [generator impactOccurred];
        
        // Clear all filters - use main thread for UI updates
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.activeTagFilters removeAllObjects];
            
            // Update collection view
            [self.tagCollectionView reloadData];
            
            [self updateUnifiedSearchResults];
            [self updateFilterIndicators];
            
            // Reload table with animation
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.tableView.numberOfSections)] withRowAnimation:UITableViewRowAnimationFade];
        });
    }];
    [alertController addAction:clearAction];
    
    // Add done option to close the menu
    UIAlertAction *doneAction = [UIAlertAction actionWithTitle:localize(@"Done", nil)
                                                        style:UIAlertActionStyleCancel
                                                      handler:nil];
    [alertController addAction:doneAction];
    
    // Present the alert on the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        // Configure popover presentation for iPad
        alertController.popoverPresentationController.barButtonItem = sender;
        
        // Animate presentation
        alertController.view.transform = CGAffineTransformMakeScale(1.1, 1.1);
        alertController.view.alpha = 0;
        
        [self presentViewController:alertController animated:YES completion:^{
            [UIView animateWithDuration:0.3 animations:^{
                alertController.view.transform = CGAffineTransformIdentity;
                alertController.view.alpha = 1;
            }];
        }];
    });
}

- (void)appendToUnifiedSearchResults:(NSArray *)newResults {
    // Validate input to prevent crashes
    if (!newResults || ![newResults isKindOfClass:[NSArray class]]) {
        NSLog(@"[ModpackInstall] Warning: appendToUnifiedSearchResults called with invalid array");
        return;
    }
    
    // Skip processing if there are no new results
    if (newResults.count == 0) {
        return;
    }
    
    // Create copies of search criteria for thread safety
    NSString *searchTextCopy = [self.searchText copy];
    NSSet *activeTagFiltersCopy = [NSSet setWithSet:self.activeTagFilters];
    
    [self.dataLock lock];
    
    // Create a set of existing IDs for efficient duplicate checking
    NSMutableSet *existingIds = [NSMutableSet set];
    for (NSDictionary *modpack in self.unifiedSearchResults) {
        if ([modpack isKindOfClass:[NSDictionary class]] && modpack[@"id"]) {
            [existingIds addObject:modpack[@"id"]];
        }
    }
    
    // Filter and add new modpacks that match search criteria
    BOOL needsResort = NO;
    for (id modpackObj in newResults) {
        if (![modpackObj isKindOfClass:[NSDictionary class]]) continue;
        
        NSDictionary *modpack = (NSDictionary *)modpackObj;
        NSString *modpackId = modpack[@"id"];
        
        // Skip duplicates more efficiently
        if (modpackId && [existingIds containsObject:modpackId]) {
            continue;
        }
        
        // Check against current filters
        BOOL matchesFilters = [self modpack:modpack matchesSearchText:searchTextCopy andTags:activeTagFiltersCopy];
        
        if (matchesFilters) {
            [self.unifiedSearchResults addObject:modpack];
            needsResort = YES;
            
            // Track this ID
            if (modpackId) {
                [existingIds addObject:modpackId];
            }
        }
    }
    
    // Only resort if needed and if we have search text
    if (needsResort && searchTextCopy.length > 0) {
        [self sortUnifiedResultsByRelevance:searchTextCopy inArray:self.unifiedSearchResults];
    }
    
    [self.dataLock unlock];
    
    // Request a table reload on the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
        
        // Update empty state visibility
        [self updateEmptyStateVisibility];
    });
}

#pragma mark - Data Loading

- (void)updateSearchResults {
    // Reset pagination when starting a fresh search
    self.hasMoreResults = YES;
    
    // Reset search text if not in search mode
    if (!self.isSearchActive) {
        self.searchText = @"";
    }
    
    // Clear existing results before loading new ones - safe thread handling
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.dataLock lock];
        [self.unifiedSearchResults removeAllObjects];
        [self.dataLock unlock];
        
        // Stop refresh control if active
        if (self.modernRefreshControl.isRefreshing) {
            [self.modernRefreshControl endRefreshing];
        }
        
        // Load fresh results asynchronously
        [self loadSearchResultsWithPrevList:NO];
    });
}

- (void)loadSearchResultsWithPrevList:(BOOL)prevList {
    // Get current search text
    NSString *name = self.searchController.searchBar.text ?: @"";
    
    // Create thread-safe copies of state
    __block BOOL isInitialLoad = !prevList && self.categories.count == 0;
    
    // Only show loading state for subsequent loads
    if (!isInitialLoad) {
        [self switchToLoadingState];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isDataLoading = NO;
        });
    }
    
    // Create a weak reference to self to avoid retain cycles
    __weak typeof(self) weakSelf = self;
    
    // Create a unique identifier for this search operation
    static NSInteger searchOperationCounter = 0;
    NSInteger currentSearchOperation = ++searchOperationCounter;
    
    // Store the operation ID to track completions
    objc_setAssociatedObject(self, @"currentSearchOperation", @(currentSearchOperation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Perform the search in background without blocking the main thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Check if this is still the current operation
        NSNumber *storedSearchOp = objc_getAssociatedObject(weakSelf, @"currentSearchOperation");
        if (!storedSearchOp || [storedSearchOp integerValue] != currentSearchOperation) {
            return; // A newer search operation has started, discard this one
        }
        
        // Create a copy of filters for this search
        NSMutableDictionary *searchFilters;
        @synchronized(self.filters) {
            searchFilters = [NSMutableDictionary dictionaryWithDictionary:self.filters];
            searchFilters[@"name"] = name;
            
            // Update main filters with current search text
            self.filters[@"name"] = name;
        }
        
        // Get previous results if appending
        NSMutableArray *prevResults = nil;
        if (prevList) {
            [weakSelf.dataLock lock];
            prevResults = [NSMutableArray arrayWithArray:weakSelf.unifiedSearchResults];
            [weakSelf.dataLock unlock];
        }
        
        // Perform the search
        NSMutableArray *newResults = [weakSelf.modrinth searchModWithFilters:searchFilters 
                                                      previousPageResult:prevResults];
        
        // Check if this is still the current operation
        storedSearchOp = objc_getAssociatedObject(weakSelf, @"currentSearchOperation");
        if (!storedSearchOp || [storedSearchOp integerValue] != currentSearchOperation) {
            return; // A newer search operation has started, discard this one
        }
        
        // Update pagination status - if we have very few or no results, force end of pagination
        BOOL hasMoreItems = !weakSelf.modrinth.reachedLastPage;
        if (!newResults || newResults.count <= 3) {
            hasMoreItems = NO;
        }
        
        // Update UI on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            // Check if view controller is still alive and this is still the current operation
            NSNumber *finalStoredOp = objc_getAssociatedObject(weakSelf, @"currentSearchOperation");
            if (!weakSelf || !finalStoredOp || [finalStoredOp integerValue] != currentSearchOperation) {
                return; // Operation was canceled or superseded
            }
            
            // Cancel any pending timeout for this operation
            NSString *timeoutKey = [NSString stringWithFormat:@"timeout_%ld", (long)currentSearchOperation];
            objc_setAssociatedObject(weakSelf, (__bridge const void *)timeoutKey, 
                                   @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            
            // Update pagination status
            weakSelf.hasMoreResults = hasMoreItems;
            weakSelf.isLoadingMoreResults = NO;
            
            if (newResults) {
                if (newResults.count == 0) {
                    // Handle empty results properly - ensure we don't try to load more
                    weakSelf.hasMoreResults = NO;
                    if (!prevList) {
                        // For a fresh search with no results, set up empty categories
                        [weakSelf organizeModpacksByCategory:@[]];
                    }
                } else {
                    if (!prevList) {
                        // For a fresh search, organize by category and update search results
                        [weakSelf organizeModpacksByCategory:newResults];
                        
                        // In search mode, also update unified results
                        if (weakSelf.isSearchActive) {
                            [weakSelf updateUnifiedSearchResults];
                        }
                    } else {
                        // For pagination, append to existing results
                        [weakSelf updateOrganizedModpacks:newResults];
                        
                        // In search mode, append to unified results
                        if (weakSelf.isSearchActive) {
                            [weakSelf appendToUnifiedSearchResults:newResults];
                        }
                    }
                }
            } else {
                // Handle error (like network failure)
                if (weakSelf.modrinth.lastError) {
                    showDialog(localize(@"Error", nil), weakSelf.modrinth.lastError.localizedDescription);
                } else {
                    showDialog(localize(@"Error", nil), @"Could not load modpacks. Please check your network connection.");
                }
                
                // Set up empty categories if needed
                if (weakSelf.categories.count == 0) {
                    [weakSelf organizeModpacksByCategory:@[]];
                }
                
                // Ensure we don't try to load more results
                weakSelf.hasMoreResults = NO;
            }
            
            // Update UI state
            [weakSelf switchToReadyState];
            
            // Update empty state visibility
            [weakSelf updateEmptyStateVisibility];
            
            // Critical: Always do a full reload for consistency
            [weakSelf.tableView reloadData];
        });
    });
    
    // Set a timeout for the operation, but don't block the main thread
    NSString *timeoutKey = [NSString stringWithFormat:@"timeout_%ld", (long)currentSearchOperation];
    objc_setAssociatedObject(self, (__bridge const void *)timeoutKey, 
                           @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Check if timeout is still active for this operation
        NSString *timeoutKey = [NSString stringWithFormat:@"timeout_%ld", (long)currentSearchOperation];
        NSNumber *isTimeoutActive = objc_getAssociatedObject(weakSelf, (__bridge const void *)timeoutKey);
        NSNumber *storedSearchOp = objc_getAssociatedObject(weakSelf, @"currentSearchOperation");
        
        // Only show timeout message if this is still the current operation and timeout wasn't canceled
        if (weakSelf && 
            isTimeoutActive && [isTimeoutActive boolValue] &&
            storedSearchOp && [storedSearchOp integerValue] == currentSearchOperation && 
            weakSelf.isDataLoading) {
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf switchToReadyState];
                showDialog(localize(@"Error", nil), @"Loading timed out. Please try again.");
                
                // Ensure we don't try to load more results
                weakSelf.hasMoreResults = NO;
                weakSelf.isLoadingMoreResults = NO;
                
                // Update empty state
                [weakSelf updateEmptyStateVisibility];
                [weakSelf.tableView reloadData];
            });
        }
    });
}

- (void)loadMoreResults {
    // Only proceed if we're not already loading and have more results to fetch
    if (self.isLoadingMoreResults || !self.hasMoreResults) {
        return;
    }
    
    // Check if we already have search results
    [self.dataLock lock];
    NSInteger currentResultCount = self.isSearchActive ? self.unifiedSearchResults.count : 0;
    [self.dataLock unlock];
    
    // If we have very few results, assume there aren't any more to load regardless of reachedLastPage flag
    if (currentResultCount <= 3) {
        self.hasMoreResults = NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.tableView reloadData];
            [self updateEmptyStateVisibility];
        });
        return;
    }
    
    // Set loading flag first to prevent multiple concurrent loads
    self.isLoadingMoreResults = YES;
    
    // Create a unique identifier for this load operation
    static NSInteger loadOperationCounter = 0;
    NSInteger currentLoadOperation = ++loadOperationCounter;
    
    // Store the operation ID to track completions
    objc_setAssociatedObject(self, @"currentLoadOperation", @(currentLoadOperation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Use a weak reference to self to prevent retain cycles
    __weak typeof(self) weakSelf = self;
    
    // Set a timeout flag that can be canceled when operation completes
    NSString *timeoutKey = [NSString stringWithFormat:@"loadTimeout_%ld", (long)currentLoadOperation];
    objc_setAssociatedObject(self, (__bridge const void *)timeoutKey, 
                           @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Set a timeout to reset loading state if the request takes too long
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Check if timeout is still active for this operation
        NSString *timeoutKey = [NSString stringWithFormat:@"loadTimeout_%ld", (long)currentLoadOperation];
        NSNumber *isTimeoutActive = objc_getAssociatedObject(weakSelf, (__bridge const void *)timeoutKey);
        
        // Only reset if this is still the current operation and timeout wasn't canceled
        NSNumber *storedOpId = objc_getAssociatedObject(weakSelf, @"currentLoadOperation");
        if (isTimeoutActive && [isTimeoutActive boolValue] && 
            storedOpId && [storedOpId integerValue] == currentLoadOperation && 
            weakSelf.isLoadingMoreResults) {
            
            weakSelf.isLoadingMoreResults = NO;
            weakSelf.hasMoreResults = NO; // Prevent further loading attempts after timeout
            NSLog(@"[ModpackInstall] Warning: Loading more results timed out (operation %ld)", (long)currentLoadOperation);
            
            // Refresh UI in case of timeout
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf.tableView reloadData];
                [weakSelf updateEmptyStateVisibility];
                
                // Show a subtle toast instead of a full dialog for pagination timeouts
                [weakSelf showToast:localize(@"Loading more results timed out", nil)];
            });
        }
    });
    
    // Start loading more results
    [self loadSearchResultsWithPrevList:YES];
}

- (void)updateEmptyStateVisibility {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Check if we need to show empty state
        BOOL shouldShowEmptyState = NO;
        
        if (self.isDataLoading) {
            // Don't show empty state while actively loading
            shouldShowEmptyState = NO;
        } else if (self.isSearchActive) {
            // In search mode, check unified results
            [self.dataLock lock];
            NSInteger resultCount = self.unifiedSearchResults.count;
            BOOL isLoading = self.isLoadingMoreResults;
            [self.dataLock unlock];
            
            shouldShowEmptyState = (resultCount == 0 && !isLoading);
        } else {
            // In regular mode, check all categories
            BOOL hasAnyModpacks = NO;
            
            [self.dataLock lock];
            for (NSArray *categoryModpacks in self.organizedModpacks) {
                if ([categoryModpacks isKindOfClass:[NSArray class]] && categoryModpacks.count > 0) {
                    hasAnyModpacks = YES;
                    break;
                }
            }
            BOOL isLoading = self.isLoadingMoreResults;
            [self.dataLock unlock];
            
            shouldShowEmptyState = (!hasAnyModpacks && !isLoading);
        }
        
        // Update empty state visibility
        self.emptyStateView.hidden = !shouldShowEmptyState;
        
        // Update empty state message based on active filters
        if (shouldShowEmptyState) {
            if (self.activeTagFilters.count > 0) {
                self.emptyStateLabel.text = localize(@"No modpacks match your current filters. Try clearing some filters.", nil);
                self.emptyStateImageView.image = [UIImage systemImageNamed:@"tag.slash"];
            } else if (self.searchController.isActive && self.searchText.length > 0) {
                self.emptyStateLabel.text = localize(@"No modpacks match your search. Try different keywords.", nil);
                self.emptyStateImageView.image = [UIImage systemImageNamed:@"magnifyingglass"];
            } else {
                self.emptyStateLabel.text = localize(@"No modpacks found. Try refreshing or check your network connection.", nil);
                self.emptyStateImageView.image = [UIImage systemImageNamed:@"cube.box"];
            }
            
            // Always animate the empty state appearance for better UX
            self.emptyStateView.alpha = 0;
            [UIView animateWithDuration:0.3 animations:^{
                self.emptyStateView.alpha = 1;
            }];
        }
    });
}

#pragma mark - UI State Management

- (void)switchToLoadingState {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Avoid double-setting loading state
        if (self.isDataLoading) return;
        
        // Create modern activity indicator
        UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        indicator.color = [UIColor systemBlueColor];
        
        // Create container view with improved visual appeal
        UIView *containerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
        containerView.backgroundColor = [UIColor secondarySystemBackgroundColor];
        containerView.layer.cornerRadius = 20;
        containerView.layer.shadowColor = [UIColor blackColor].CGColor;
        containerView.layer.shadowOffset = CGSizeMake(0, 2);
        containerView.layer.shadowOpacity = 0.1;
        containerView.layer.shadowRadius = 4;
        
        // Add indicator to container
        indicator.center = CGPointMake(containerView.bounds.size.width / 2, containerView.bounds.size.height / 2);
        [containerView addSubview:indicator];
        [indicator startAnimating];
        
        // Only use the close button in the navigation bar
        UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] 
                                       initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                       target:self 
                                       action:@selector(actionClose)];
        
        self.navigationItem.rightBarButtonItems = @[closeButton];
        
        // Set loading indicator on table footer instead to prevent interfering with navigation bar
        UIView *loadingFooterView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.tableView.bounds.size.width, 80)];
        UIActivityIndicatorView *footerIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        footerIndicator.center = CGPointMake(loadingFooterView.bounds.size.width / 2, loadingFooterView.bounds.size.height / 2);
        [loadingFooterView addSubview:footerIndicator];
        [footerIndicator startAnimating];
        
        self.tableView.tableFooterView = loadingFooterView;
        
        // Prevent dismissal during loading
        self.navigationController.modalInPresentation = YES;
        self.tableView.allowsSelection = NO;
        
        // Update loading state flag
        self.isDataLoading = YES;
        
        // Hide empty state view during loading
        self.emptyStateView.hidden = YES;
    });
}

- (void)switchToReadyState {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Avoid double-setting ready state
        if (!self.isDataLoading) return;
        
        // Remove the loading footer
        self.tableView.tableFooterView = nil;
        
        // Restore normal navigation items with modern styling
        UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] 
                                       initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                       target:self 
                                       action:@selector(actionClose)];
        
        // Update right bar button items to only include the close button
        self.navigationItem.rightBarButtonItems = @[closeButton];
        
        // Allow dismissal and interaction again
        self.navigationController.modalInPresentation = NO;
        self.tableView.allowsSelection = YES;
        
        // Stop refresh control if active
        [self.modernRefreshControl endRefreshing];
        
        // Update loading state flag
        self.isDataLoading = NO;
    });
}

- (void)updateFilterIndicators {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Update collection view to reflect current filter state
        [self.tagCollectionView reloadData];
    });
}

#pragma mark - Data Organization and Filtering

- (void)organizeModpacksByCategory:(NSArray *)modpacks {
    // Guard against nil input
    if (!modpacks) {
        modpacks = @[];
    }
    
    [self.dataLock lock];
    
    // Clear previous data
    [self.categories removeAllObjects];
    [self.visibilityList removeAllObjects];
    [self.organizedModpacks removeAllObjects];
    [self.filteredModpacks removeAllObjects];
    
    // If no modpacks, add empty category
    if (modpacks.count == 0) {
        [self.categories addObject:localize(@"No Results", nil)];
        [self.visibilityList addObject:@YES];
        [self.organizedModpacks addObject:[NSMutableArray array]];
        [self.filteredModpacks addObject:[NSMutableArray array]];
        [self.dataLock unlock];
        return;
    }
    
    // Create dictionary to group modpacks by category
    NSMutableDictionary *categorizedModpacks = [NSMutableDictionary dictionary];
    
    // Default categories for organization
    NSArray *defaultCategories = @[
        localize(@"Featured Modpacks", nil),
        localize(@"Magic Modpacks", nil),
        localize(@"Tech Modpacks", nil),
        localize(@"Adventure Modpacks", nil),
        localize(@"Other Modpacks", nil)
    ];
    
    // Initialize categories
    for (NSString *category in defaultCategories) {
        categorizedModpacks[category] = [NSMutableArray array];
    }
    
    // Define expanded keywords for better categorization
    NSDictionary *categoryKeywords = @{
        localize(@"Magic Modpacks", nil): @[@"magic", @"wizard", @"spell", @"arcane", @"mage", @"witch", @"sorcery", @"mystical", @"enchant", @"thaumcraft", @"blood magic", @"botania"],
        
        localize(@"Tech Modpacks", nil): @[@"tech", @"machine", @"redstone", @"industrial", @"energy", @"power", @"mechanism", @"factory", @"automation", @"engineer", @"buildcraft", @"immersive engineering", @"thermal", @"computercraft", @"create"],
        
        localize(@"Adventure Modpacks", nil): @[@"adventure", @"quest", @"explore", @"journey", @"dungeon", @"rpg", @"dimension", @"battle", @"biome", @"structure", @"twilight forest", @"aether"]
    };
    
    // Create a safe copy of modpacks to iterate through
    NSArray *safeModpacks = [modpacks copy];
    
    // Pre-process for quicker text search
    NSMutableDictionary *keywordCache = [NSMutableDictionary dictionary];
    for (NSString *category in categoryKeywords) {
        NSArray *keywords = categoryKeywords[category];
        for (NSString *keyword in keywords) {
            keywordCache[keyword] = category;
        }
    }
    
    // Assign modpacks to categories based on keywords
    for (id modpackObj in safeModpacks) {
        if (![modpackObj isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        
        NSDictionary *modpack = (NSDictionary *)modpackObj;
        
        NSString *title = [[modpack[@"title"] ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *description = [[modpack[@"description"] ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        
        // Ensure tags is an array
        id tagsObj = modpack[@"categories"];
        NSArray *tags = [tagsObj isKindOfClass:[NSArray class]] ? tagsObj : @[];
        
        // Create a safe copy of tags to iterate through
        NSArray *safeTags = [tags copy];
        
        // Start with a score for each category
        NSMutableDictionary *categoryScores = [NSMutableDictionary dictionary];
        for (NSString *category in defaultCategories) {
            categoryScores[category] = @0;
        }
        
        // Calculate a score for each category based on keyword matching
        // Use pre-processed keyword cache for faster lookups
        NSArray *titleWords = [title componentsSeparatedByString:@" "];
        for (NSString *word in titleWords) {
            NSString *category = keywordCache[word];
            if (category) {
                int currentScore = [categoryScores[category] intValue];
                categoryScores[category] = @(currentScore + 5);
            }
        }
        
        // Check for partial matches in title and description
        for (NSString *category in categoryKeywords) {
            NSArray *keywords = categoryKeywords[category];
            
            for (NSString *keyword in keywords) {
                if ([title containsString:keyword]) {
                    int currentScore = [categoryScores[category] intValue];
                    categoryScores[category] = @(currentScore + 2);
                }
                
                if ([description containsString:keyword]) {
                    int currentScore = [categoryScores[category] intValue];
                    categoryScores[category] = @(currentScore + 1);
                }
                
                // Check tags for this keyword
                for (id tagObj in safeTags) {
                    if (![tagObj isKindOfClass:[NSString class]]) continue;
                    
                    NSString *tag = [(NSString *)tagObj lowercaseString];
                    if ([tag isEqualToString:keyword]) {
                        int currentScore = [categoryScores[category] intValue];
                        categoryScores[category] = @(currentScore + 5);
                    } else if ([tag containsString:keyword]) {
                        int currentScore = [categoryScores[category] intValue];
                        categoryScores[category] = @(currentScore + 3);
                    }
                }
            }
        }
        
        // Find the category with the highest score
        NSString *bestCategory = localize(@"Other Modpacks", nil);
        int highestScore = 0;
        
        for (NSString *category in categoryScores) {
            int score = [categoryScores[category] intValue];
            if (score > highestScore) {
                highestScore = score;
                bestCategory = category;
            }
        }
        
        // If no category had a score, use the default "Other"
        NSString *category = (highestScore > 0) ? bestCategory : localize(@"Other Modpacks", nil);
        
        // Add to appropriate category - check for valid arrays first
        NSMutableArray *categoryArray = categorizedModpacks[category];
        if (categoryArray && [categoryArray isKindOfClass:[NSMutableArray class]]) {
            [categoryArray addObject:modpack];
        } else {
            // If category doesn't exist for some reason, add to Other
            NSMutableArray *otherArray = categorizedModpacks[localize(@"Other Modpacks", nil)];
            if (otherArray && [otherArray isKindOfClass:[NSMutableArray class]]) {
                [otherArray addObject:modpack];
            }
        }
    }
    
    // Feature the first few modpacks regardless of category
    NSMutableArray *featuredModpacks = [NSMutableArray array];
    NSInteger featuredCount = MIN(5, modpacks.count);
    for (NSInteger i = 0; i < featuredCount; i++) {
        if (i < safeModpacks.count) {
            [featuredModpacks addObject:safeModpacks[i]];
        }
    }
    
    if (categorizedModpacks[localize(@"Featured Modpacks", nil)]) {
        categorizedModpacks[localize(@"Featured Modpacks", nil)] = featuredModpacks;
    }
    
    // Build the final organized arrays
    for (NSString *category in defaultCategories) {
        NSMutableArray *modpacksInCategory = categorizedModpacks[category];
        
        // Only add non-empty categories
        if (modpacksInCategory && modpacksInCategory.count > 0) {
            [self.categories addObject:category];
            [self.visibilityList addObject:@(YES)]; // Start expanded by default
            [self.organizedModpacks addObject:modpacksInCategory];
            [self.filteredModpacks addObject:[modpacksInCategory mutableCopy]];
        }
    }
    
    // If no categories were created (which shouldn't happen), add a fallback
    if (self.categories.count == 0) {
        [self.categories addObject:localize(@"All Modpacks", nil)];
        [self.visibilityList addObject:@YES];
        [self.organizedModpacks addObject:[modpacks mutableCopy]];
        [self.filteredModpacks addObject:[modpacks mutableCopy]];
    }
    
    [self.dataLock unlock];
}

- (void)updateOrganizedModpacks:(NSArray *)newModpacks {
    // Validate input to prevent crashes
    if (!newModpacks || ![newModpacks isKindOfClass:[NSArray class]]) {
        NSLog(@"[ModpackInstall] Warning: updateOrganizedModpacks called with invalid array");
        return;
    }
    
    [self.dataLock lock];
    
    // Create a set to track existing modpack IDs
    NSMutableSet *existingModpackIds = [NSMutableSet set];
    
    // Collect all existing modpack IDs to avoid duplicates
    for (NSArray *categoryModpacks in self.organizedModpacks) {
        if (![categoryModpacks isKindOfClass:[NSArray class]]) continue;
        
        for (NSDictionary *modpack in categoryModpacks) {
            if (![modpack isKindOfClass:[NSDictionary class]]) continue;
            
            if ([modpack[@"id"] isKindOfClass:[NSString class]]) {
                [existingModpackIds addObject:modpack[@"id"]];
            }
        }
    }
    
    // For simplicity, we'll just add all new modpacks to the "Other" category
    NSString *otherCategory = localize(@"Other Modpacks", nil);
    
    // Find or create the "Other" category
    NSUInteger otherIndex = [self.categories indexOfObject:otherCategory];
    if (otherIndex == NSNotFound) {
        [self.categories addObject:otherCategory];
        [self.visibilityList addObject:@YES];
        [self.organizedModpacks addObject:[NSMutableArray array]];
        [self.filteredModpacks addObject:[NSMutableArray array]];
        otherIndex = self.categories.count - 1;
    }
    
    // Add new modpacks to the "Other" category, checking for duplicates
    if (otherIndex < self.organizedModpacks.count) {
        NSMutableArray *otherModpacks = self.organizedModpacks[otherIndex];
        if ([otherModpacks isKindOfClass:[NSMutableArray class]]) {
            // Create a copy of new modpacks to avoid mutation issues during iteration
            NSArray *safeNewModpacks = [newModpacks copy];
            
            for (NSDictionary *newModpack in safeNewModpacks) {
                // Skip if not a dictionary
                if (![newModpack isKindOfClass:[NSDictionary class]]) continue;
                
                // Skip if this modpack ID is already in our collection
                if ([newModpack[@"id"] isKindOfClass:[NSString class]] && 
                    [existingModpackIds containsObject:newModpack[@"id"]]) {
                    continue;
                }
                
                // Add this modpack and track its ID
                [otherModpacks addObject:newModpack];
                if ([newModpack[@"id"] isKindOfClass:[NSString class]]) {
                    [existingModpackIds addObject:newModpack[@"id"]];
                }
            }
        }
    }
    
    if (otherIndex < self.filteredModpacks.count) {
        NSMutableArray *filteredOtherModpacks = self.filteredModpacks[otherIndex];
        if ([filteredOtherModpacks isKindOfClass:[NSMutableArray class]]) {
            // Create a copy of new modpacks to avoid mutation issues during iteration
            NSArray *safeNewModpacks = [newModpacks copy];
            
            for (NSDictionary *newModpack in safeNewModpacks) {
                // Skip if not a dictionary
                if (![newModpack isKindOfClass:[NSDictionary class]]) continue;
                
                // Skip if this modpack ID is already in our collection
                if ([newModpack[@"id"] isKindOfClass:[NSString class]] && 
                    [existingModpackIds containsObject:newModpack[@"id"]]) {
                    continue;
                }
                
                // Add to filtered list as well
                [filteredOtherModpacks addObject:newModpack];
            }
        }
    }
    
    // For search mode, also append to unified search results if they match the current criteria
    if (self.isSearchActive) {
        // Create safe copies of the current search criteria
        NSString *currentSearchText = [self.searchText copy];
        NSSet *activeTagFiltersCopy = [NSSet setWithSet:self.activeTagFilters];
        
        // Create a copy of new modpacks to avoid mutation issues during iteration
        NSArray *safeNewModpacks = [newModpacks copy];
        
        for (id modpackObj in safeNewModpacks) {
            // Ensure the modpack is a dictionary
            if (![modpackObj isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            
            NSDictionary *modpack = (NSDictionary *)modpackObj;
            
            // Skip if this modpack ID is already in our collection
            if ([modpack[@"id"] isKindOfClass:[NSString class]] && 
                [existingModpackIds containsObject:modpack[@"id"]]) {
                continue;
            }
            
            // Check if the modpack passes our current filters
            BOOL matchesFilters = [self modpack:modpack matchesSearchText:currentSearchText andTags:activeTagFiltersCopy];
            
            // Add the modpack if it matches our filters
            if (matchesFilters) {
                [self.unifiedSearchResults addObject:modpack];
            }
        }
        
        // Re-sort if we added any items and have search text
        if (currentSearchText.length > 0 && self.unifiedSearchResults.count > 0) {
            [self sortUnifiedResultsByRelevance:currentSearchText inArray:self.unifiedSearchResults];
        }
    }
    
    [self.dataLock unlock];
}

- (void)updateUnifiedSearchResults {
    // Early exit if not in search mode
    if (!self.isSearchActive) {
        return;
    }
    
    // Safely make copies of filter criteria before locking
    NSString *searchTextCopy = [self.searchText copy];
    NSSet *activeTagFiltersCopy = [NSSet setWithSet:self.activeTagFilters];
    
    // Acquire lock for thread safety
    [self.dataLock lock];
    
    // Create a new array - don't modify the existing one while iterating
    NSMutableArray *filteredResults = [NSMutableArray array];
    
    // Create a set to track unique modpack IDs
    NSMutableSet *addedModpackIds = [NSMutableSet set];
    
    // If search is empty and no tag filters, skip filtering to avoid unnecessary work
    if (searchTextCopy.length == 0 && activeTagFiltersCopy.count == 0) {
        // Just use existing results if any
        if (self.unifiedSearchResults.count > 0) {
            [self.dataLock unlock];
            return;
        }
        
        // Otherwise, compile all modpacks from categories
        for (NSArray *categoryModpacks in self.organizedModpacks) {
            if (![categoryModpacks isKindOfClass:[NSArray class]]) continue;
            
            for (NSDictionary *modpack in categoryModpacks) {
                if (![modpack isKindOfClass:[NSDictionary class]]) continue;
                
                // Skip duplicates by ID
                NSString *modpackId = modpack[@"id"];
                if (modpackId && [addedModpackIds containsObject:modpackId]) {
                    continue;
                }
                
                [filteredResults addObject:modpack];
                
                // Track this ID to avoid duplicates
                if (modpackId) {
                    [addedModpackIds addObject:modpackId];
                }
            }
        }
        
        // Use the new results array
        self.unifiedSearchResults = filteredResults;
        [self.dataLock unlock];
        return;
    }
    
    // Apply filtering on all modpacks across categories
    for (NSArray *categoryModpacks in self.organizedModpacks) {
        if (![categoryModpacks isKindOfClass:[NSArray class]]) continue;
        
        for (NSDictionary *modpack in categoryModpacks) {
            if (![modpack isKindOfClass:[NSDictionary class]]) continue;
            
            // Skip duplicate modpacks by ID
            NSString *modpackId = modpack[@"id"];
            if (modpackId && [addedModpackIds containsObject:modpackId]) {
                continue;
            }
            
            // Check if the modpack matches search criteria
            BOOL matchesFilters = [self modpack:modpack matchesSearchText:searchTextCopy andTags:activeTagFiltersCopy];
            
            if (matchesFilters) {
                [filteredResults addObject:modpack];
                
                // Track this ID to avoid duplicates
                if (modpackId) {
                    [addedModpackIds addObject:modpackId];
                }
            }
        }
    }
    
    // Sort results by relevance if search text is provided
    if (searchTextCopy.length > 0) {
        [self sortUnifiedResultsByRelevance:searchTextCopy inArray:filteredResults];
        
        // Replace the current results with the filtered and sorted array
        self.unifiedSearchResults = filteredResults;
    } else {
        // Just use the filtered array without sorting
        self.unifiedSearchResults = filteredResults;
    }
    
    [self.dataLock unlock];
    
    // Update empty state visibility
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateEmptyStateVisibility];
        [self.tableView reloadData];
    });
}

// Method to sort results by relevance to search term
- (void)sortUnifiedResultsByRelevance:(NSString *)searchText inArray:(NSMutableArray *)arrayToSort {
    // Convert search text to lowercase once for efficiency
    NSString *lowercaseSearchText = [searchText lowercaseString];
    
    [arrayToSort sortUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
        // Extract titles and perform quick comparison - avoiding unnecessary string operations
        NSString *title1 = obj1[@"title"] ?: @"";
        NSString *title2 = obj2[@"title"] ?: @"";
        
        // Use cached lowercase versions for multiple comparisons
        NSString *lowercaseTitle1 = [title1 lowercaseString];
        NSString *lowercaseTitle2 = [title2 lowercaseString];
        
        // Quick exact match check
        BOOL isExactMatch1 = [lowercaseTitle1 isEqualToString:lowercaseSearchText];
        BOOL isExactMatch2 = [lowercaseTitle2 isEqualToString:lowercaseSearchText];
        
        if (isExactMatch1 && !isExactMatch2) return NSOrderedAscending;
        if (!isExactMatch1 && isExactMatch2) return NSOrderedDescending;
        
        // Faster prefix check
        BOOL isPrefixMatch1 = [lowercaseTitle1 hasPrefix:lowercaseSearchText];
        BOOL isPrefixMatch2 = [lowercaseTitle2 hasPrefix:lowercaseSearchText];
        
        if (isPrefixMatch1 && !isPrefixMatch2) return NSOrderedAscending;
        if (!isPrefixMatch1 && isPrefixMatch2) return NSOrderedDescending;
        
        // Contains check
        BOOL containsMatch1 = [lowercaseTitle1 containsString:lowercaseSearchText];
        BOOL containsMatch2 = [lowercaseTitle2 containsString:lowercaseSearchText];
        
        if (containsMatch1 && !containsMatch2) return NSOrderedAscending;
        if (!containsMatch1 && containsMatch2) return NSOrderedDescending;
        
        // Category check - only if needed
        BOOL hasInCategories1 = NO;
        BOOL hasInCategories2 = NO;
        
        // Only check categories if needed (avoid unnecessary iteration)
        if (!containsMatch1 || !containsMatch2) {
            NSArray *categories1 = obj1[@"categories"];
            if ([categories1 isKindOfClass:[NSArray class]]) {
                for (NSString *category in categories1) {
                    if ([[category lowercaseString] containsString:lowercaseSearchText]) {
                        hasInCategories1 = YES;
                        break;
                    }
                }
            }
            
            NSArray *categories2 = obj2[@"categories"];
            if ([categories2 isKindOfClass:[NSArray class]]) {
                for (NSString *category in categories2) {
                    if ([[category lowercaseString] containsString:lowercaseSearchText]) {
                        hasInCategories2 = YES;
                        break;
                    }
                }
            }
            
            if (hasInCategories1 && !hasInCategories2) return NSOrderedAscending;
            if (!hasInCategories1 && hasInCategories2) return NSOrderedDescending;
        }
        
        // Popularity based on download count if available
        NSNumber *downloads1 = obj1[@"downloads"];
        NSNumber *downloads2 = obj2[@"downloads"];
        
        if (downloads1 && downloads2) {
            return [downloads2 compare:downloads1]; // Higher downloads first
        }
        
        // Alphabetical sort as last resort
        return [title1 localizedCaseInsensitiveCompare:title2];
    }];
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    // Store search text
    NSString *newSearchText = searchController.searchBar.text ?: @"";
    
    // Only update if the search text actually changed
    if ([self.searchText isEqualToString:newSearchText]) {
        return;
    }
    
    self.searchText = newSearchText;
    
    // Make sure isSearchActive is set correctly
    if (searchController.active && !self.isSearchActive) {
        self.isSearchActive = YES;
    }
    
    // Debounce search with a cancelable delay
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateSearchAndRefreshUI) object:nil];
    [self performSelector:@selector(updateSearchAndRefreshUI) withObject:nil afterDelay:0.3];
}

- (void)updateSearchAndRefreshUI {
    // Update search results only if we're in search mode
    if (self.isSearchActive) {
        [self updateUnifiedSearchResults];
        
        // Only reload the data on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.tableView reloadData];
            [self updateEmptyStateVisibility];
        });
    }
}


#pragma mark - UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // Don't process if not in search mode or already loading
    if (!self.isSearchActive || self.isLoadingMoreResults || !self.hasMoreResults) {
        return;
    }
    
    // Check if we have sufficient results to warrant loading more
    [self.dataLock lock];
    NSInteger currentResultCount = self.unifiedSearchResults.count;
    [self.dataLock unlock];
    
    // If we have very few results, assume there aren't any more to load
    if (currentResultCount <= 3) {
        self.hasMoreResults = NO;
        return;
    }
    
    // Check if we're near the bottom of the table view and should load more
    CGFloat currentOffset = scrollView.contentOffset.y;
    CGFloat contentHeight = scrollView.contentSize.height;
    CGFloat frameHeight = scrollView.frame.size.height;

    // Only trigger when closer to the bottom to prevent excessive loading attempts
    CGFloat loadMoreThreshold = MIN(frameHeight * 0.5, 100); 
    CGFloat bottomDistance = contentHeight - (currentOffset + frameHeight);
    
    if (bottomDistance < loadMoreThreshold && contentHeight > frameHeight * 1.5) {
        [self loadMoreResults];
    }
}

#pragma mark - UIContextMenu

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location
{
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        return self.currentMenu;
    }];
}

- (_UIContextMenuStyle *)_contextMenuInteraction:(UIContextMenuInteraction *)interaction styleForMenuWithConfiguration:(UIContextMenuConfiguration *)configuration
{
    _UIContextMenuStyle *style = [_UIContextMenuStyle defaultStyle];
    style.preferredLayout = 3; // _UIContextMenuLayoutCompactMenu
    return style;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (self.isDataLoading) {
        return 1; // Show a single section with loading indicator
    }
    
    // When in search mode, show a single section
    if (self.isSearchActive) {
        return 1;
    }
    
    [self.dataLock lock];
    NSInteger count = self.categories.count;
    [self.dataLock unlock];
    
    return count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.isDataLoading) {
        return 3; // Show multiple shimmer cells for better UX
    }
    
    // When in search mode, show unified search results
    if (self.isSearchActive) {
        [self.dataLock lock];
        NSInteger count = self.unifiedSearchResults.count;
        BOOL hasMore = self.hasMoreResults;
        [self.dataLock unlock];
        
        // If we have no results but might get more, show a loading indicator
        if (count == 0 && hasMore) {
            return 3; // Show 3 shimmer cells
        }
        
        // If we have results and might get more, add 1 for the loading indicator
        if (count > 0 && hasMore) {
            return count + 1;
        }
        
        // Otherwise just show the results (or a "no results" row if empty)
        return MAX(count, 1);
    }
    
    [self.dataLock lock];
    
    // Add bounds checking
    if (section >= self.visibilityList.count) {
        [self.dataLock unlock];
        return 0;
    }
    
    // If the section is collapsed, don't show any rows
    if (!self.visibilityList[section].boolValue) {
        [self.dataLock unlock];
        return 0;
    }
    
    NSInteger rows = 0;
    
    if (section < self.organizedModpacks.count) {
        rows = self.organizedModpacks[section].count;
    }
    
    [self.dataLock unlock];
    
    // Better handling of empty categories
    if (rows == 0 && self.categories.count == 1) {
        // If we only have one category and it's empty, show a "No results" message
        return 1;
    } else if (rows == 0) {
        // If this particular category is empty, don't show any rows
        return 0;
    } else {
        // Return the actual number of rows
        return rows;
    }
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    // When in search mode, never show section headers
    if (self.isSearchActive) {
        return nil;
    }
    
    ModpackCategoryHeaderView *headerView = [tableView dequeueReusableHeaderFooterViewWithIdentifier:@"ModpackCategoryHeader"];
    
    // Return a loading header if data is still loading
    if (self.isDataLoading) {
        headerView.titleLabel.text = localize(@"Loading modpacks...", nil);
        headerView.isExpanded = NO;
        headerView.expandCollapseButton.tag = section;
        [headerView.expandCollapseButton removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
        return headerView;
    }
    
    [self.dataLock lock];
    
    // Add bounds checking
    if (section >= self.categories.count || self.categories.count == 0) {
        [self.dataLock unlock];
        headerView.titleLabel.text = localize(@"No Results", nil);
        headerView.isExpanded = NO;
        headerView.expandCollapseButton.tag = section;
        [headerView.expandCollapseButton removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
        return headerView;
    }
    
    // Apply section title
    headerView.titleLabel.text = self.categories[section];
    
    // Set expanded state
    if (section < self.visibilityList.count) {
        headerView.isExpanded = self.visibilityList[section].boolValue;
    } else {
        headerView.isExpanded = NO;
    }
    
    [self.dataLock unlock];
    
    // Store section index
    headerView.expandCollapseButton.tag = section;
    
    // Remove existing targets to avoid duplicate actions
    [headerView.expandCollapseButton removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
    
    // Add action for the button
    [headerView.expandCollapseButton addTarget:self action:@selector(toggleSection:) forControlEvents:UIControlEventTouchUpInside];
    
    return headerView;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    // When in search mode, don't show section headers at all
    if (self.isSearchActive) {
        return 0.0;
    }
    
    return 60.0;
}

- (void)toggleSection:(UIButton *)sender {
    // Add haptic feedback
    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [generator prepare];
    [generator impactOccurred];
    
    if (self.isDataLoading) {
        return;
    }
    
    NSInteger section = sender.tag;
    
    [self.dataLock lock];
    
    if (section >= 0 && section < self.visibilityList.count && self.categories.count > section) {
        // Toggle section visibility
        self.visibilityList[section] = @(!self.visibilityList[section].boolValue);
        
        [self.dataLock unlock];
        
        // Update section on the main thread with animation
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:section] withRowAnimation:UITableViewRowAnimationFade];
        });
    } else {
        [self.dataLock unlock];
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 110.0; // Increased height for better visuals
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Show shimmer cells when loading or for the loading more indicator
    if (self.isDataLoading) {
        ShimmerCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ShimmerCell" forIndexPath:indexPath];
        return cell;
    }
    
    // SEARCH MODE: Determine correct cell type based on index path
    if (self.isSearchActive) {
        [self.dataLock lock];
        NSInteger resultsCount = self.unifiedSearchResults.count;
        BOOL hasMore = self.hasMoreResults;
        [self.dataLock unlock];
        
        // If we're showing the loading indicator row (last row when more results available)
        if (hasMore && indexPath.row == resultsCount) {
            // Use shimmer cell for loading state
            ShimmerCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ShimmerCell" forIndexPath:indexPath];
            
            // Trigger loading more results if not already loading
            if (!self.isLoadingMoreResults) {
                [self loadMoreResults];
            }
            
            return cell;
        }
        
        // For actual content, use the ModpackVersionCell
        ModpackVersionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModpackVersionCell" forIndexPath:indexPath];
        return [self configureSearchModeCellAtIndexPath:indexPath cell:cell];
    }
    
    // CATEGORY MODE: Standard content cell
    ModpackVersionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModpackVersionCell" forIndexPath:indexPath];
    return [self configureCategoryModeCellAtIndexPath:indexPath cell:cell];
}

// Helper method for configuring cells in search mode
- (UITableViewCell *)configureSearchModeCellAtIndexPath:(NSIndexPath *)indexPath cell:(ModpackVersionCell *)cell {
    // Safely access data with proper locking
    [self.dataLock lock];
    
    NSInteger resultsCount = self.unifiedSearchResults.count;
    
    // If we have no results
    if (resultsCount == 0) {
        [self.dataLock unlock];
        
        cell.titleLabel.text = localize(@"No modpacks found", nil);
        cell.subtitleLabel.text = localize(@"Try changing your search criteria", nil);
        [cell setTags:@[]];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.modpackIconView.image = [UIImage systemImageNamed:@"cube.box"];
        cell.modpackIconView.tintColor = [UIColor systemGray3Color];
        
        return cell;
    }
    
    // Make sure the index path is in range
    if (indexPath.row >= resultsCount) {
        [self.dataLock unlock];
        
        // Return a generic cell if out of range
        cell.titleLabel.text = @"";
        cell.subtitleLabel.text = @"";
        [cell setTags:@[]];
        return cell;
    }
    
    // Create a safe copy of the modpack data
    NSDictionary *modpack = [self.unifiedSearchResults[indexPath.row] copy];
    
    [self.dataLock unlock];
    
    // Configure cell with the modpack data
    [self configureCell:cell withModpack:modpack];
    
    return cell;
}

// Helper method for configuring cells in category mode
- (UITableViewCell *)configureCategoryModeCellAtIndexPath:(NSIndexPath *)indexPath cell:(ModpackVersionCell *)cell {
    [self.dataLock lock];
    
    // Add bounds checking
    BOOL outOfBounds = (indexPath.section >= self.organizedModpacks.count || 
                       (indexPath.section < self.organizedModpacks.count && 
                        indexPath.row >= [self.organizedModpacks[indexPath.section] count]));
    
    if (outOfBounds || [self.organizedModpacks[indexPath.section] count] == 0) {
        [self.dataLock unlock];
        
        // Return an empty state cell
        cell.titleLabel.text = localize(@"No modpacks found", nil);
        cell.subtitleLabel.text = localize(@"Try changing your search criteria", nil);
        [cell setTags:@[]];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.modpackIconView.image = [UIImage systemImageNamed:@"cube.box"];
        cell.modpackIconView.tintColor = [UIColor systemGray3Color];
        
        return cell;
    }
    
    // Create a safe copy of the modpack data
    NSDictionary *modpack = [self.organizedModpacks[indexPath.section][indexPath.row] copy];
    
    [self.dataLock unlock];
    
    // Configure cell with the modpack data
    [self configureCell:cell withModpack:modpack];
    
    return cell;
}

// Helper method for configuring a cell with modpack data
- (void)configureCell:(ModpackVersionCell *)cell withModpack:(NSDictionary *)modpack {
    // Safely extract values with type checking
    NSString *title = [modpack[@"title"] isKindOfClass:[NSString class]] ? modpack[@"title"] : @"Unknown";
    NSString *description = [modpack[@"description"] isKindOfClass:[NSString class]] ? modpack[@"description"] : @"";
    NSString *imageUrl = [modpack[@"imageUrl"] isKindOfClass:[NSString class]] ? modpack[@"imageUrl"] : @"";
    NSArray *categories = [modpack[@"categories"] isKindOfClass:[NSArray class]] ? modpack[@"categories"] : @[];
    
    // Update the cell with modpack data
    cell.titleLabel.text = title;
    cell.subtitleLabel.text = description;
    
    // Set tags from categories
    [cell setTags:categories];
    
    // Set modpack icon with improved image loading
    cell.modpackIconView.image = nil; // Reset image first to avoid stale images
    UIImage *fallbackImage = [UIImage imageNamed:@"DefaultProfile"] ?: [UIImage systemImageNamed:@"cube.fill"];
    
    if (imageUrl.length > 0) {
        // Convert WebP URLs to supported formats
        imageUrl = [cell convertWebPUrl:imageUrl];
        
        // Create an absolute URL if it's not already
        NSURL *iconURL = [NSURL URLWithString:imageUrl];
        
        // Extra validation for URL
        if (!iconURL) {
            cell.modpackIconView.image = fallbackImage;
        } else {
            // Use the shared image downloader from AFNetworking with clear cache policy
            NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:iconURL];
            [request setHTTPShouldHandleCookies:NO];
            [request setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData]; // Force reload, ignore cache
            
            // Set a specific timeout to avoid long waits
            [request setTimeoutInterval:15.0];
            
            // Cancel any previous image requests for this cell to prevent wrong images
            [cell.modpackIconView cancelImageDownloadTask];
            
            // Use a tag to track which image URL is being loaded for this cell
            static int lastTag = 1000;
            int currentTag = ++lastTag;
            cell.modpackIconView.tag = currentTag;
            
            // Use the AFNetworking category with our custom request
            [cell.modpackIconView setImageWithURLRequest:request 
                                        placeholderImage:fallbackImage 
                                                 success:^(NSURLRequest *request, NSHTTPURLResponse *response, UIImage *image) {
                                                     // Only update if the tag still matches (cell hasn't been reused)
                                                     if (cell.modpackIconView.tag == currentTag) {
                                                         // Apply the image with a fade-in animation
                                                         [UIView transitionWithView:cell.modpackIconView
                                                                           duration:0.3
                                                                            options:UIViewAnimationOptionTransitionCrossDissolve
                                                                         animations:^{
                                                                             cell.modpackIconView.image = image;
                                                                         } completion:nil];
                                                     }
                                                 } 
                                                 failure:^(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error) {
                                                     // Ensure fallback image is set if the tag still matches
                                                     if (cell.modpackIconView.tag == currentTag) {
                                                         cell.modpackIconView.image = fallbackImage;
                                                     }
                                                 }];
        }
    } else {
        // If no URL, use fallback immediately
        cell.modpackIconView.image = fallbackImage;
    }
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    // Add haptic feedback for better user experience
    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [generator prepare];
    [generator impactOccurred];
    
    // Skip if data is still loading
    if (self.isDataLoading) {
        return;
    }
    
    // Skip if this is the "loading more" row in search mode
    if (self.isSearchActive && self.hasMoreResults && indexPath.row == self.unifiedSearchResults.count) {
        return;
    }
    
    NSDictionary *modpack = nil;
    
    // Thread-safe access to get the modpack data
    [self.dataLock lock];
    
    // Get the modpack based on whether we're in search mode or category mode
    if (self.isSearchActive) {
        // Check bounds for search mode
        if (indexPath.row < self.unifiedSearchResults.count && self.unifiedSearchResults.count > 0) {
            // Make a safe copy to avoid race conditions
            modpack = [self.unifiedSearchResults[indexPath.row] copy];
        }
    } else {
        // Check bounds for category mode
        if (indexPath.section < self.organizedModpacks.count && 
            indexPath.row < [self.organizedModpacks[indexPath.section] count] && 
            self.organizedModpacks.count > 0) {
            // Make a safe copy to avoid race conditions
            modpack = [self.organizedModpacks[indexPath.section][indexPath.row] copy];
        }
    }
    
    [self.dataLock unlock];
    
    // Check if we got a valid modpack
    if (!modpack) {
        NSLog(@"[ModpackInstall] Error: No valid modpack found at indexPath (%ld, %ld)", 
              (long)indexPath.section, (long)indexPath.row);
        return;
    }
    
    // Check if details already loaded
    if ([modpack[@"versionDetailsLoaded"] boolValue]) {
        // Show version selection menu
        [self showVersionMenu:modpack atIndexPath:indexPath];
    } else {
        // Load details first - preserve original categories
        NSMutableDictionary *modpackCopy = [modpack mutableCopy];
        
        // Store original categories to ensure modloader info isn't lost
        if ([modpack[@"categories"] isKindOfClass:[NSArray class]]) {
            modpackCopy[@"original_categories"] = [modpack[@"categories"] copy];
        }
        
        // Load details first
        [self loadModpackDetails:modpackCopy atIndexPath:indexPath];
    }
}

- (void)loadModpackDetails:(NSMutableDictionary *)modpack atIndexPath:(NSIndexPath *)indexPath {
    // Show loading indicator
    ModpackVersionCell *cell = (ModpackVersionCell *)[self.tableView cellForRowAtIndexPath:indexPath];
    if (!cell) {
        return; // Cell might have been scrolled offscreen
    }
    
    // Create a modern loading indicator with animation
    UIView *loadingContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 30, 30)];
    loadingContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    loadingContainer.layer.cornerRadius = 15;
    
    UIActivityIndicatorView *activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    activityIndicator.color = [UIColor systemBlueColor];
    activityIndicator.center = CGPointMake(15, 15);
    [loadingContainer addSubview:activityIndicator];
    [activityIndicator startAnimating];
    
    cell.accessoryView = loadingContainer;
    cell.accessoryType = UITableViewCellAccessoryNone;
    
    // Create a weak reference to self to avoid retain cycles
    __weak typeof(self) weakSelf = self;
    
    // Store a reference to cell for cancellation check
    static int lastCellTagOperation = 0;
    int thisOperation = ++lastCellTagOperation;
    objc_setAssociatedObject(cell, @"detailLoadOperation", @(thisOperation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    
    // Load details in background
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [weakSelf.modrinth loadDetailsOfMod:modpack];
        
        // Check if this operation was cancelled by a new one
        if (!cell) {
            return; // Cell is no longer available, operation might be cancelled
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            // Check if this is still the current operation
            NSNumber *currentOperation = objc_getAssociatedObject(cell, @"detailLoadOperation");
            if (![currentOperation isEqual:@(thisOperation)]) {
                return; // A newer operation is in progress, discard this one
            }
            
            // Update cell to use disclosure indicator - check if cell is still visible
            UITableViewCell *updatedCell = [weakSelf.tableView cellForRowAtIndexPath:indexPath];
            if (updatedCell) {
                updatedCell.accessoryView = nil;
                updatedCell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            }
            
            // Update data model - find the modpack in all lists and update it
            [weakSelf updateModpackInDataStructures:modpack];
            
            // If icon URL has been updated, reload image - check if cell is still visible
            if (modpack[@"imageUrl"] && [updatedCell isKindOfClass:[ModpackVersionCell class]]) {
                ModpackVersionCell *versionCell = (ModpackVersionCell *)updatedCell;
                
                // Create an absolute URL if it's not already
                NSString *imageUrl = [modpack[@"imageUrl"] isKindOfClass:[NSString class]] ? modpack[@"imageUrl"] : @"";
                imageUrl = [versionCell convertWebPUrl:imageUrl];
                NSURL *iconURL = [NSURL URLWithString:imageUrl];
                
                // Use the shared image downloader from AFNetworking with clear cache policy
                NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:iconURL];
                [request setHTTPShouldHandleCookies:NO];
                [request setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData]; // Force reload, ignore cache
                [request setTimeoutInterval:15.0];
                
                // Cancel any previous image tasks
                [versionCell.modpackIconView cancelImageDownloadTask];
                
                // Use a tag to track which image URL is being loaded
                static int lastImageTag = 1000;
                int currentImageTag = ++lastImageTag;
                versionCell.modpackIconView.tag = currentImageTag;
                
                // Load the updated image
                [versionCell.modpackIconView setImageWithURLRequest:request 
                                                   placeholderImage:versionCell.modpackIconView.image ?: [UIImage imageNamed:@"DefaultProfile"]
                                                            success:^(NSURLRequest *request, NSHTTPURLResponse *response, UIImage *image) {
                                                                if (versionCell.modpackIconView.tag == currentImageTag) {
                                                                    [UIView transitionWithView:versionCell.modpackIconView
                                                                                      duration:0.3
                                                                                       options:UIViewAnimationOptionTransitionCrossDissolve
                                                                                    animations:^{
                                                                                        versionCell.modpackIconView.image = image;
                                                                                    } completion:nil];
                                                                }
                                                            } failure:nil];
                
                // Fix the tag duplication issue by creating a unique set of categories
                NSMutableSet *uniqueCategories = [NSMutableSet set];
                
                // Add new categories if they exist
                if ([modpack[@"categories"] isKindOfClass:[NSArray class]]) {
                    [uniqueCategories addObjectsFromArray:modpack[@"categories"]];
                }
                
                // Add original categories if they exist and weren't already added
                if ([modpack[@"original_categories"] isKindOfClass:[NSArray class]]) {
                    [uniqueCategories addObjectsFromArray:modpack[@"original_categories"]];
                }
                
                // Convert set back to array for the tags
                NSArray *uniqueCategoriesArray = [uniqueCategories allObjects];
                
                // Update the cell's tags with the unique categories
                [versionCell setTags:uniqueCategoriesArray];
            }
            
            // Show version menu if details loaded successfully
            if ([modpack[@"versionDetailsLoaded"] boolValue]) {
                [weakSelf showVersionMenu:modpack atIndexPath:indexPath];
            } else {
                if (weakSelf.modrinth.lastError) {
                    showDialog(localize(@"Error", nil), weakSelf.modrinth.lastError.localizedDescription);
                } else {
                    showDialog(localize(@"Error", nil), @"Failed to load modpack details. Please try again later.");
                }
            }
        });
    });
}

// Helper method to update modpack data across all data structures
- (void)updateModpackInDataStructures:(NSDictionary *)modpack {
    [self.dataLock lock];
    
    // Get the modpack ID for comparison
    NSString *modpackId = modpack[@"id"];
    if (!modpackId) {
        [self.dataLock unlock];
        return;
    }
    
    // Update in organized lists
    for (NSMutableArray *category in self.organizedModpacks) {
        if (![category isKindOfClass:[NSMutableArray class]]) continue;
        
        for (NSInteger i = 0; i < category.count; i++) {
            NSDictionary *item = category[i];
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            
            if ([item[@"id"] isEqual:modpackId]) {
                category[i] = modpack;
            }
        }
    }
    
    // Update in filtered lists
    for (NSMutableArray *category in self.filteredModpacks) {
        if (![category isKindOfClass:[NSMutableArray class]]) continue;
        
        for (NSInteger i = 0; i < category.count; i++) {
            NSDictionary *item = category[i];
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            
            if ([item[@"id"] isEqual:modpackId]) {
                category[i] = modpack;
            }
        }
    }
    
    // Update in unified search results
    for (NSInteger i = 0; i < self.unifiedSearchResults.count; i++) {
        NSDictionary *item = self.unifiedSearchResults[i];
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        
        if ([item[@"id"] isEqual:modpackId]) {
            self.unifiedSearchResults[i] = modpack;
        }
    }
    
    [self.dataLock unlock];
}

- (void)showVersionMenu:(NSDictionary *)modpack atIndexPath:(NSIndexPath *)indexPath {
    ModpackVersionCell *cell = (ModpackVersionCell *)[self.tableView cellForRowAtIndexPath:indexPath];
    if (!cell) {
        // The cell might have been scrolled off-screen
        // Create a new temporary cell that won't be displayed just to handle the menu
        cell = [[ModpackVersionCell alloc] init];
        cell.modpackIconView = [[UIImageView alloc] init];
        cell.modpackIconView.image = [UIImage imageNamed:@"DefaultProfile"];
    }
    
    NSMutableArray<UIAction *> *menuItems = [[NSMutableArray alloc] init];
    
    // Validate the version arrays
    NSArray *versionNames = modpack[@"versionNames"];
    NSArray *mcVersionNames = modpack[@"mcVersionNames"];
    
    if (!versionNames || ![versionNames isKindOfClass:[NSArray class]] || 
        !mcVersionNames || ![mcVersionNames isKindOfClass:[NSArray class]]) {
        showDialog(localize(@"Error", nil), @"Invalid version information. Please try again.");
        return;
    }
    
    // Create a weak reference to self to prevent retain cycles
    __weak typeof(self) weakSelf = self;
    
    // Add a title menu item
    UIAction *titleAction = [UIAction actionWithTitle:modpack[@"title"] 
                                                image:[UIImage systemImageNamed:@"info.circle"]
                                           identifier:nil
                                              handler:^(UIAction *action) {
                                                  // No action - this is just a title
                                              }];
    titleAction.attributes = UIMenuElementAttributesDisabled;
    [menuItems addObject:titleAction];
    
    // Check if we have any versions
    if (versionNames.count == 0) {
        UIAction *noVersionsAction = [UIAction actionWithTitle:localize(@"No versions available", nil)
                                                         image:nil
                                                    identifier:nil
                                                       handler:^(UIAction *action) {}];
        noVersionsAction.attributes = UIMenuElementAttributesDisabled;
        [menuItems addObject:noVersionsAction];
    } else {
        // Add a separator
        UIAction *separator = [UIAction actionWithTitle:localize(@"Select version to install:", nil)
                                                  image:nil
                                             identifier:nil
                                                handler:^(UIAction *action) {}];
        separator.attributes = UIMenuElementAttributesDisabled;
        [menuItems addObject:separator];
        
        // Add version actions
        [versionNames enumerateObjectsUsingBlock:
        ^(NSString *name, NSUInteger i, BOOL *stop) {
            // Skip invalid indices
            if (i >= mcVersionNames.count) return;
            
            // Skip non-string values
            if (![name isKindOfClass:[NSString class]] || 
                ![mcVersionNames[i] isKindOfClass:[NSString class]]) return;
            
            NSString *nameWithVersion = name;
            NSString *mcVersion = mcVersionNames[i];
            if (![name hasSuffix:mcVersion]) {
                nameWithVersion = [NSString stringWithFormat:@"%@ - %@", name, mcVersion];
            }
            
            // Determine the appropriate icon based on Minecraft version
            UIImage *versionIcon = nil;
            if ([mcVersion hasPrefix:@"1.20"]) {
                versionIcon = [UIImage systemImageNamed:@"star.fill"];
            } else if ([mcVersion hasPrefix:@"1.19"]) {
                versionIcon = [UIImage systemImageNamed:@"star"];
            } else if ([mcVersion hasPrefix:@"1.18"]) {
                versionIcon = [UIImage systemImageNamed:@"mountain.2.fill"];
            } else if ([mcVersion hasPrefix:@"1.17"]) {
                versionIcon = [UIImage systemImageNamed:@"mountain.2"];
            } else if ([mcVersion hasPrefix:@"1.16"]) {
                versionIcon = [UIImage systemImageNamed:@"flame.fill"];
            } else {
                versionIcon = [UIImage systemImageNamed:@"cube.box.fill"];
            }
            
            [menuItems addObject:[UIAction
                actionWithTitle:nameWithVersion
                image:versionIcon
                identifier:nil
                handler:^(UIAction *action) {
                    [weakSelf actionClose];
                    
                    // Create a mutable copy of modpack to include original categories
                    NSMutableDictionary *modpackWithCategories = [modpack mutableCopy];
                    
                    // If we have original categories stored, make sure they're included
                    if (modpack[@"original_categories"]) {
                        NSMutableArray *allCategories = [NSMutableArray array];
                        
                        // Add original categories
                        if ([modpack[@"original_categories"] isKindOfClass:[NSArray class]]) {
                            [allCategories addObjectsFromArray:modpack[@"original_categories"]];
                        }
                        
                        // Add new categories if different from originals
                        if ([modpack[@"categories"] isKindOfClass:[NSArray class]]) {
                            for (id category in modpack[@"categories"]) {
                                if (![allCategories containsObject:category]) {
                                    [allCategories addObject:category];
                                }
                            }
                        }
                        
                        // Use the combined categories
                        modpackWithCategories[@"categories"] = allCategories;
                    }
                    
                    // Safely create the icon path
                    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
                    UIImage *iconImage = cell.modpackIconView.image ?: [UIImage systemImageNamed:@"cube.fill"];
                    [UIImagePNGRepresentation([iconImage _imageWithSize:CGSizeMake(40, 40)]) writeToFile:tmpIconPath atomically:YES];
                    
                    // Add haptic feedback for selection
                    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
                    [generator prepare];
                    [generator impactOccurred];
                    
                    // Safely install the modpack with preserved categories
                    [weakSelf.modrinth installModpackFromDetail:modpackWithCategories atIndex:i];
                }]];
        }];
    }
    
    // If no valid menu items, show error
    if (menuItems.count <= 2) { // Title + separator only
        showDialog(localize(@"Error", nil), @"No valid versions available for this modpack.");
        return;
    }
    
    // Create modern menu with sections
    self.currentMenu = [UIMenu menuWithTitle:@"" children:menuItems];
    UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    
    // Only set interactions if cell is visible
    if ([cell superview]) {
        cell.interactions = @[interaction];
        [interaction _presentMenuAtLocation:CGPointZero];
    } else {
        // If cell isn't visible, present menu from a fixed point
        UIView *containerView = self.view;
        containerView.interactions = @[interaction];
        [interaction _presentMenuAtLocation:CGPointMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2)];
    }
}

@end
