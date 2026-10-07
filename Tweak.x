#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

// Passe a 0 une fois que tout marche (les toasts servent de debug, faute de logs).
#define BL_DEBUG_TOASTS 1

// Actif par defaut. Pour desactiver : defaults write com.google.ios.youtubemusic BetterLyricsDisabled -bool YES
#define BL_ENABLED() (![[NSUserDefaults standardUserDefaults] boolForKey:@"BetterLyricsDisabled"])

#pragma mark - Declarations minimales des classes de YouTube Music

@interface YTIVideoDetails : NSObject
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, copy, readwrite) NSString *author;
@end

@interface YTIPlayerResponse : NSObject
@property (nonatomic, assign, readonly) YTIVideoDetails *videoDetails;
@end

@interface YTPlayerResponse : NSObject
@property (nonatomic, assign, readonly) YTIPlayerResponse *playerData;
@end

@interface YTPlayerViewController : UIViewController
@property (nonatomic, assign, readonly) YTPlayerResponse *playerResponse;
@property (nonatomic, assign, readonly) CGFloat currentVideoTotalMediaTime;
- (NSString *)currentVideoID;
- (CGFloat)currentVideoMediaTime;
- (void)seekToTime:(CGFloat)time;
@end

static NSString *const BLLyricsDidLoadNotification = @"BLLyricsDidLoadNotification";

#pragma mark - Modele

@interface BLLine : NSObject
@property (nonatomic, assign) NSTimeInterval time;
@property (nonatomic, copy) NSString *text;
@end
@implementation BLLine
@end

@interface BLStore : NSObject
@property (atomic, copy) NSString *videoID;
@property (atomic, copy) NSArray<BLLine *> *lines;
@property (atomic, assign) NSTimeInterval lastTime;
@property (atomic, assign) CFTimeInterval lastStamp;
@property (atomic, weak) YTPlayerViewController *player;
+ (instancetype)shared;
@end
@implementation BLStore
+ (instancetype)shared {
    static BLStore *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [BLStore new]; });
    return s;
}
@end

// Temps de lecture estime : le player ne notifie que ~1 fois/s, on interpole entre deux notifications.
static NSTimeInterval BLCurrentTime(void) {
    BLStore *s = [BLStore shared];
    CFTimeInterval dt = CACurrentMediaTime() - s.lastStamp;
    if (dt < 0) dt = 0;
    if (dt > 1.5) dt = 1.5; // si la lecture est en pause, on arrete d'avancer
    return s.lastTime + dt;
}

static NSInteger BLIndexForTime(NSArray<BLLine *> *lines, NSTimeInterval t) {
    NSInteger idx = -1;
    for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
        if (lines[i].time <= t) idx = i; else break;
    }
    return idx;
}

#pragma mark - Parsing LRC

static NSArray<BLLine *> *BLParseLRC(NSString *lrc) {
    static NSRegularExpression *tagRE, *wordRE;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tagRE = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d{1,3}):(\\d{1,2}(?:[\\.:]\\d{1,3})?)\\]" options:0 error:nil];
        wordRE = [NSRegularExpression regularExpressionWithPattern:@"<\\d{1,3}:\\d{1,2}(?:[\\.:]\\d{1,3})?>" options:0 error:nil];
    });

    NSMutableArray<BLLine *> *out = [NSMutableArray array];
    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];

    for (NSString *raw in [lrc componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSArray<NSTextCheckingResult *> *tags = [tagRE matchesInString:raw options:0 range:NSMakeRange(0, raw.length)];
        if (tags.count == 0) continue; // lignes de metadonnees ([ar:...], [ti:...])

        NSString *text = [raw substringFromIndex:NSMaxRange(tags.lastObject.range)];
        text = [wordRE stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
        text = [text stringByTrimmingCharactersInSet:ws];

        for (NSTextCheckingResult *m in tags) {
            double min = [[raw substringWithRange:[m rangeAtIndex:1]] doubleValue];
            NSString *secStr = [[raw substringWithRange:[m rangeAtIndex:2]] stringByReplacingOccurrencesOfString:@":" withString:@"."];
            BLLine *l = [BLLine new];
            l.time = min * 60.0 + [secStr doubleValue];
            l.text = text;
            [out addObject:l];
        }
    }

    [out sortUsingComparator:^NSComparisonResult(BLLine *a, BLLine *b) {
        return a.time < b.time ? NSOrderedAscending : (a.time > b.time ? NSOrderedDescending : NSOrderedSame);
    }];
    return out;
}

#pragma mark - Reseau (LRCLIB)

static NSString *BLClean(NSString *s, BOOL isArtist) {
    if (!s.length) return @"";
    NSMutableString *m = [s mutableCopy];
    if (isArtist) {
        [m replaceOccurrencesOfString:@" - Topic" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, m.length)];
        [m replaceOccurrencesOfString:@"VEVO" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, m.length)];
    } else {
        // retire "(Official Video)", "[Lyrics]", etc.
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\s*[\\(\\[][^\\)\\]]*(official|video|lyric|audio|visuali[sz]er|hd|4k)[^\\)\\]]*[\\)\\]]" options:NSRegularExpressionCaseInsensitive error:nil];
        [re replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@""];
    }
    return [m stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static void BLToast(NSString *msg) {
#if BL_DEBUG_TOASTS
    dispatch_async(dispatch_get_main_queue(), ^{
        Class c = NSClassFromString(@"YTMToastController");
        id toast = c ? [[c alloc] init] : nil;
        SEL sel = NSSelectorFromString(@"showMessage:");
        if (toast && [toast respondsToSelector:sel]) {
            void (*send)(id, SEL, NSString *) = (void (*)(id, SEL, NSString *))objc_msgSend;
            send(toast, sel, msg);
        }
    });
#endif
}

static void BLFinish(NSString *videoID, NSArray<BLLine *> *lines) {
    BLStore *s = [BLStore shared];
    if (![s.videoID isEqualToString:videoID]) return; // la piste a change entre-temps
    s.lines = lines ?: @[];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:BLLyricsDidLoadNotification object:nil];
    });
    BLToast(lines.count ? [NSString stringWithFormat:@"Better Lyrics : %lu lignes (LRCLIB)", (unsigned long)lines.count]
                        : @"Better Lyrics : pas de paroles synchronisees");
}

static NSURLRequest *BLRequest(NSString *path, NSArray<NSURLQueryItem *> *items) {
    NSURLComponents *c = [NSURLComponents componentsWithString:[@"https://lrclib.net/api/" stringByAppendingString:path]];
    c.queryItems = items;
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:c.URL];
    r.timeoutInterval = 10;
    // LRCLIB demande un User-Agent identifiable
    [r setValue:@"YTMusicUltimate-BetterLyrics (iOS tweak)" forHTTPHeaderField:@"User-Agent"];
    return r;
}

static NSString *BLSynced(NSDictionary *d) {
    id v = d[@"syncedLyrics"];
    return ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) ? v : nil;
}

static void BLFetch(NSString *videoID, NSString *title, NSString *artist, double duration) {
    NSString *t = BLClean(title, NO), *a = BLClean(artist, YES);
    NSString *dur = [NSString stringWithFormat:@"%d", (int)round(duration)];

    NSURLRequest *getReq = BLRequest(@"get", @[
        [NSURLQueryItem queryItemWithName:@"track_name" value:t],
        [NSURLQueryItem queryItemWithName:@"artist_name" value:a],
        [NSURLQueryItem queryItemWithName:@"duration" value:dur],
    ]);

    [[[NSURLSession sharedSession] dataTaskWithRequest:getReq completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
        if (!err && code == 200 && data) {
            NSDictionary *d = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *lrc = [d isKindOfClass:[NSDictionary class]] ? BLSynced(d) : nil;
            if (lrc) { BLFinish(videoID, BLParseLRC(lrc)); return; }
        }

        // Repli : recherche, on garde le resultat synchronise dont la duree est la plus proche.
        NSURLRequest *searchReq = BLRequest(@"search", @[
            [NSURLQueryItem queryItemWithName:@"track_name" value:t],
            [NSURLQueryItem queryItemWithName:@"artist_name" value:a],
        ]);
        [[[NSURLSession sharedSession] dataTaskWithRequest:searchReq completionHandler:^(NSData *data2, NSURLResponse *resp2, NSError *err2) {
            NSString *best = nil; double bestDiff = 1e9;
            NSArray *arr = (!err2 && data2) ? [NSJSONSerialization JSONObjectWithData:data2 options:0 error:nil] : nil;
            if ([arr isKindOfClass:[NSArray class]]) {
                for (NSDictionary *d in arr) {
                    if (![d isKindOfClass:[NSDictionary class]]) continue;
                    NSString *lrc = BLSynced(d);
                    if (!lrc) continue;
                    double diff = fabs([d[@"duration"] doubleValue] - duration);
                    if (diff < bestDiff) { bestDiff = diff; best = lrc; }
                }
            }
            BLFinish(videoID, (best && bestDiff <= 4.0) ? BLParseLRC(best) : nil);
        }] resume];
    }] resume];
}

#pragma mark - Hook du player (titre, artiste, temps)

static void BLTick(YTPlayerViewController *pvc) {
    if (!BL_ENABLED()) return;
    NSString *vid = pvc.currentVideoID;
    if (!vid.length) return;

    BLStore *s = [BLStore shared];
    s.player = pvc;
    s.lastTime = pvc.currentVideoMediaTime;
    s.lastStamp = CACurrentMediaTime();

    if ([vid isEqualToString:s.videoID]) return;

    YTIVideoDetails *d = pvc.playerResponse.playerData.videoDetails;
    double dur = pvc.currentVideoTotalMediaTime;
    if (!d.title.length || dur <= 0) return; // pas encore pret : on reessaie au prochain tick

    s.videoID = vid;
    s.lines = nil;
    BLFetch(vid, d.title, d.author, dur);
}

%hook YTPlayerViewController
- (void)singleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;
    BLTick(self);
}
- (void)potentiallyMutatedSingleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;
    BLTick(self);
}
%end

#pragma mark - Affichage dans l'onglet Paroles

@interface BLWeakTarget : NSObject
@property (nonatomic, weak) id target;
- (void)tick:(CADisplayLink *)link;
@end
@implementation BLWeakTarget
- (void)tick:(CADisplayLink *)link {
    id t = self.target;
    if (t) [t performSelector:NSSelectorFromString(@"blTick")];
    else [link invalidate];
}
@end

@interface YTMLightweightMusicDescriptionShelfCell : UIView
@property (retain, nonatomic) UITextView *blView;
@property (retain, nonatomic) CADisplayLink *blLink;
@property (retain, nonatomic) NSArray *blRanges;
@property (assign, nonatomic) NSInteger blIndex;
- (void)blRefresh;
- (void)blTick;
@end

%hook YTMLightweightMusicDescriptionShelfCell

%property (retain, nonatomic) UITextView *blView;
%property (retain, nonatomic) CADisplayLink *blLink;
%property (retain, nonatomic) NSArray *blRanges;
%property (assign, nonatomic) NSInteger blIndex;

- (void)didMoveToWindow {
    %orig;

    if (self.window && BL_ENABLED()) {
        if (!self.blView) {
            UIView *container = [self valueForKey:@"_descriptionContainer"];
            UITextView *tv = [[UITextView alloc] init];
            tv.backgroundColor = [UIColor clearColor];
            tv.editable = NO;
            tv.selectable = NO;
            tv.scrollEnabled = NO;
            tv.textContainerInset = UIEdgeInsetsZero;
            tv.textContainer.lineFragmentPadding = 0;
            tv.hidden = YES;
            [tv addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(blTapped:)]];
            [container addSubview:tv];
            self.blView = tv;
        }

        [[NSNotificationCenter defaultCenter] removeObserver:self name:BLLyricsDidLoadNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(blRefresh) name:BLLyricsDidLoadNotification object:nil];

        if (!self.blLink) {
            BLWeakTarget *wt = [BLWeakTarget new];
            wt.target = self;
            CADisplayLink *link = [CADisplayLink displayLinkWithTarget:wt selector:@selector(tick:)];
            link.preferredFramesPerSecond = 30;
            [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            self.blLink = link;
        }
        [self blRefresh];
    } else {
        [self.blLink invalidate];
        self.blLink = nil;
        [[NSNotificationCenter defaultCenter] removeObserver:self name:BLLyricsDidLoadNotification object:nil];
    }
}

- (void)setRenderer:(id)renderer {
    %orig;
    if (BL_ENABLED() && self.blView) [self blRefresh];
}

- (void)layoutSubviews {
    %orig;
    if (!BL_ENABLED() || !self.blView) return;

    UILabel *label = [self valueForKey:@"_descriptionLabel"];
    CGRect f = label.frame;
    if (!self.blView.hidden && f.size.width > 0) {
        CGFloat h = [self.blView sizeThatFits:CGSizeMake(f.size.width, CGFLOAT_MAX)].height;
        f.size.height = MAX(f.size.height, ceil(h));
    }
    self.blView.frame = f;
}

%new
- (void)blRefresh {
    UILabel *label = [self valueForKey:@"_descriptionLabel"];
    NSArray<BLLine *> *lines = [BLStore shared].lines;

    if (!lines.count) {
        self.blView.hidden = YES;
        label.hidden = NO;
        self.blRanges = nil;
        self.blIndex = -2;
        return;
    }

    UIFont *font = label.font ?: [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineSpacing = 6;
    ps.paragraphSpacing = 14;

    NSMutableAttributedString *full = [NSMutableAttributedString new];
    NSMutableArray *ranges = [NSMutableArray arrayWithCapacity:lines.count];
    UIColor *dim = [(label.textColor ?: [UIColor whiteColor]) colorWithAlphaComponent:0.4];

    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *txt = lines[i].text.length ? lines[i].text : @"\u266A";
        NSString *piece = [txt stringByAppendingString:(i + 1 < lines.count ? @"\n" : @"")];
        NSRange r = NSMakeRange(full.length, piece.length);
        [full appendAttributedString:[[NSAttributedString alloc] initWithString:piece attributes:@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: dim,
            NSParagraphStyleAttributeName: ps,
        }]];
        [ranges addObject:[NSValue valueWithRange:r]];
    }

    self.blRanges = ranges;
    self.blIndex = -2; // force le prochain tick a recolorer
    self.blView.attributedText = full;
    self.blView.hidden = NO;
    label.hidden = YES;
    [self setNeedsLayout];
    [self blTick];
}

%new
- (void)blTick {
    NSArray<BLLine *> *lines = [BLStore shared].lines;
    if (!lines.count || !self.blRanges.count || self.blView.hidden) return;

    NSInteger idx = BLIndexForTime(lines, BLCurrentTime() + 0.15); // petite avance pour compenser la latence
    if (idx == self.blIndex) return;

    UILabel *label = [self valueForKey:@"_descriptionLabel"];
    UIColor *base = label.textColor ?: [UIColor whiteColor];
    NSTextStorage *ts = self.blView.textStorage;

    [ts beginEditing];
    if (self.blIndex >= 0 && self.blIndex < (NSInteger)self.blRanges.count) {
        [ts addAttribute:NSForegroundColorAttributeName value:[base colorWithAlphaComponent:0.4]
                   range:[self.blRanges[self.blIndex] rangeValue]];
    }
    if (idx >= 0 && idx < (NSInteger)self.blRanges.count) {
        [ts addAttribute:NSForegroundColorAttributeName value:[base colorWithAlphaComponent:1.0]
                   range:[self.blRanges[idx] rangeValue]];
    }
    [ts endEditing];

    self.blIndex = idx;
    if (idx < 0) return;

    // Defilement automatique (sauf si l'utilisateur est en train de scroller)
    UIScrollView *sv = nil;
    for (UIView *v = self.superview; v; v = v.superview) {
        if ([v isKindOfClass:[UIScrollView class]] && ((UIScrollView *)v).contentSize.height > v.bounds.size.height) {
            sv = (UIScrollView *)v; break;
        }
    }
    if (!sv || sv.isTracking || sv.isDragging || sv.isDecelerating) return;

    NSRange glyphs = [self.blView.layoutManager glyphRangeForCharacterRange:[self.blRanges[idx] rangeValue] actualCharacterRange:NULL];
    CGRect rect = [self.blView.layoutManager boundingRectForGlyphRange:glyphs inTextContainer:self.blView.textContainer];
    CGRect inSV = [self.blView convertRect:rect toView:sv];

    CGFloat minY = -sv.adjustedContentInset.top;
    CGFloat maxY = MAX(minY, sv.contentSize.height - sv.bounds.size.height + sv.adjustedContentInset.bottom);
    CGFloat target = MIN(MAX(CGRectGetMidY(inSV) - sv.bounds.size.height * 0.35, minY), maxY);

    [UIView animateWithDuration:0.35 delay:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseOut
                     animations:^{ sv.contentOffset = CGPointMake(sv.contentOffset.x, target); }
                     completion:nil];
}

%new
- (void)blTapped:(UITapGestureRecognizer *)tap {
    NSArray<BLLine *> *lines = [BLStore shared].lines;
    if (!lines.count || !self.blRanges.count) return;

    CGPoint p = [tap locationInView:self.blView];
    NSUInteger ch = [self.blView.layoutManager characterIndexForPoint:p
                                                      inTextContainer:self.blView.textContainer
                             fractionOfDistanceBetweenInsertionPoints:NULL];
    for (NSUInteger i = 0; i < self.blRanges.count; i++) {
        if (NSLocationInRange(ch, [self.blRanges[i] rangeValue])) {
            [[BLStore shared].player seekToTime:lines[i].time];
            break;
        }
    }
}

%end
