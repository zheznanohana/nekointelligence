// GMShell.m — 单窗口外壳（App Store 式：左侧边栏 = 功能，右侧 = 内容）
//
// 设计依据（apple-design skill / HIG）：
//   · 主窗口用系统 NSSplitViewController + 侧边栏材质，不自绘窗口 UI（windows.md › Best practices）
//   · 侧边栏只两层：「写作」「设置」两组，SF Symbols 图标，跟随系统强调色（sidebars.md）
//   · 当前视图的动作放在工具栏，并且每个工具栏项都能在菜单栏里找到（toolbars.md › Desktop）
//   · 关键信息和操作不放在窗口/侧边栏底部（layout.md › Desktop、sidebars.md › Desktop）
//   · 只用语义色，浅色/深色自动跟随，不做 App 内外观开关（color.md、dark-mode.md）
//   · 明确告诉用户结果由哪个模型生成、可能出错、可以撤销（generative-ai.md）
//
// 供应商配置保存在 ~/Library/Application Support/AppleIntel/providers.json，
// 中继（GMBridge）每次请求都会重新读取，所以保存即生效。

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import "GMLang.h"

// GMBridge.m
NSString *GMBridgeAsk(NSDictionary *provider, NSString *system, NSString *user, int maxTokens, NSString **errOut);
NSDictionary *GMBridgeActiveProvider(void);
// GMSetup.m
BOOL GMAutostartEnabled(void);
void GMSetupSetAutostart(BOOL on);
// AIHost.m
BOOL AIHGetAutoCopy(void);
void AIHSetAutoCopy(BOOL on);

static NSString *GMHome(void){
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/AppleIntel"];
}
static NSString *GMCfgPath(void){ return [GMHome() stringByAppendingPathComponent:@"providers.json"]; }
static NSString *GMLogPath(void){ return [GMHome() stringByAppendingPathComponent:@"qwen_proxy.log"]; }

#pragma mark - 小工具

static NSImage *GMSym(NSString *name, NSString *fallback, NSString *desc){
    NSImage *i = [NSImage imageWithSystemSymbolName:name accessibilityDescription:desc];
    if (!i && fallback) i = [NSImage imageWithSystemSymbolName:fallback accessibilityDescription:desc];
    return i;
}

static NSTextField *GMLabel(NSString *s, NSFont *font, NSColor *color){
    NSTextField *t = [NSTextField labelWithString:s ?: @""];
    t.font = font ?: [NSFont systemFontOfSize:NSFont.systemFontSize];
    t.textColor = color ?: NSColor.labelColor;
    t.translatesAutoresizingMaskIntoConstraints = NO;
    return t;
}
static NSTextField *GMWrap(NSString *s, NSFont *font, NSColor *color){
    NSTextField *t = [NSTextField wrappingLabelWithString:s ?: @""];
    t.font = font ?: [NSFont systemFontOfSize:NSFont.systemFontSize];
    t.textColor = color ?: NSColor.secondaryLabelColor;
    t.selectable = NO;
    t.translatesAutoresizingMaskIntoConstraints = NO;
    [t setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return t;
}
static NSButton *GMButton(NSString *title, id target, SEL sel){
    NSButton *b = [NSButton buttonWithTitle:title target:target action:sel];
    b.bezelStyle = NSBezelStyleRounded;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}
static NSColor *GMGroupFill(void){
    if (@available(macOS 14.0, *)) return NSColor.quaternarySystemFillColor;
    return [NSColor.labelColor colorWithAlphaComponent:0.04];
}

// 页面大标题 + 说明
static NSStackView *GMHeader(NSString *title, NSTextField **subOut, NSString *sub){
    NSTextField *t = GMLabel(title, [NSFont systemFontOfSize:26 weight:NSFontWeightBold], NSColor.labelColor);
    t.accessibilityRole = NSAccessibilityStaticTextRole;
    NSTextField *s = GMWrap(sub, [NSFont systemFontOfSize:13], NSColor.secondaryLabelColor);
    if (subOut) *subOut = s;
    NSStackView *v = [NSStackView stackViewWithViews:@[t, s]];
    v.orientation = NSUserInterfaceLayoutOrientationVertical;
    v.alignment = NSLayoutAttributeLeading;
    v.spacing = 4;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    return v;
}

static NSTextField *GMSection(NSString *s){
    return GMLabel(s, [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], NSColor.labelColor);
}

// System Settings 风格的彩色小方块图标
static NSView *GMTile(NSString *sym, NSString *fallback, NSColor *color){
    NSBox *b = [NSBox new];
    b.boxType = NSBoxCustom; b.borderWidth = 0; b.cornerRadius = 6;
    b.fillColor = color ?: NSColor.controlAccentColor;
    b.contentViewMargins = NSZeroSize;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.widthAnchor constraintEqualToConstant:24].active = YES;
    [b.heightAnchor constraintEqualToConstant:24].active = YES;
    NSImageView *iv = [NSImageView imageViewWithImage:GMSym(sym, fallback, nil) ?: [NSImage new]];
    iv.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightSemibold];
    iv.contentTintColor = NSColor.whiteColor;
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    [b addSubview:iv];
    [iv.centerXAnchor constraintEqualToAnchor:b.centerXAnchor].active = YES;
    [iv.centerYAnchor constraintEqualToAnchor:b.centerYAnchor].active = YES;
    return b;
}

// 一行：图标 + 标题/说明 + 右侧控件
static NSView *GMRow(NSView *tile, NSString *title, NSString *detail, NSView *accessory){
    NSTextField *t = GMLabel(title, [NSFont systemFontOfSize:13], NSColor.labelColor);
    NSMutableArray *texts = [NSMutableArray arrayWithObject:t];
    if (detail.length) [texts addObject:GMWrap(detail, [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor)];
    NSStackView *tv = [NSStackView stackViewWithViews:texts];
    tv.orientation = NSUserInterfaceLayoutOrientationVertical;
    tv.alignment = NSLayoutAttributeLeading; tv.spacing = 2;
    [tv setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [tv setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSView *spacer = [NSView new];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [spacer setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSMutableArray *views = [NSMutableArray array];
    if (tile) [views addObject:tile];
    [views addObject:tv];
    [views addObject:spacer];
    if (accessory) {
        accessory.translatesAutoresizingMaskIntoConstraints = NO;
        [accessory setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [views addObject:accessory];
    }
    NSStackView *row = [NSStackView stackViewWithViews:views];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 10;
    row.distribution = NSStackViewDistributionFill;
    row.edgeInsets = NSEdgeInsetsMake(9, 12, 9, 12);
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return row;
}

// 圆角分组框（行之间自动加分隔线）
static NSBox *GMGroup(NSArray<NSView*> *rows){
    NSMutableArray *vs = [NSMutableArray array];
    for (NSUInteger i = 0; i < rows.count; i++) {
        if (i) {
            NSBox *sep = [NSBox new]; sep.boxType = NSBoxSeparator;
            sep.translatesAutoresizingMaskIntoConstraints = NO;
            [vs addObject:sep];
        }
        [vs addObject:rows[i]];
    }
    NSStackView *st = [NSStackView stackViewWithViews:vs];
    st.orientation = NSUserInterfaceLayoutOrientationVertical;
    st.alignment = NSLayoutAttributeWidth;
    st.spacing = 0;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    NSBox *b = [NSBox new];
    b.boxType = NSBoxCustom; b.borderWidth = 0; b.cornerRadius = 10;
    b.fillColor = GMGroupFill();
    b.contentViewMargins = NSZeroSize;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b addSubview:st];
    [NSLayoutConstraint activateConstraints:@[
        [st.leadingAnchor constraintEqualToAnchor:b.leadingAnchor],
        [st.trailingAnchor constraintEqualToAnchor:b.trailingAnchor],
        [st.topAnchor constraintEqualToAnchor:b.topAnchor],
        [st.bottomAnchor constraintEqualToAnchor:b.bottomAnchor],
    ]];
    return b;
}

static NSTextField *GMKeycap(NSString *s){
    NSTextField *t = GMLabel(s, [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightMedium], NSColor.secondaryLabelColor);
    return t;
}

@interface GMFlipView : NSView @end
@implementation GMFlipView - (BOOL)isFlipped { return YES; } @end

// 可滚动的页面：顶部对齐，内容最大宽度 720
static NSScrollView *GMScrollPage(NSStackView *content){
    NSScrollView *sv = [NSScrollView new];
    sv.hasVerticalScroller = YES; sv.autohidesScrollers = YES;
    sv.drawsBackground = NO; sv.borderType = NSNoBorder;
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    GMFlipView *doc = [GMFlipView new];
    doc.translatesAutoresizingMaskIntoConstraints = NO;
    sv.documentView = doc;
    [doc addSubview:content];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    NSLayoutConstraint *maxW = [content.widthAnchor constraintLessThanOrEqualToConstant:720];
    NSLayoutConstraint *fill = [content.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor constant:-32];
    fill.priority = NSLayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [doc.leadingAnchor constraintEqualToAnchor:sv.contentView.leadingAnchor],
        [doc.trailingAnchor constraintEqualToAnchor:sv.contentView.trailingAnchor],
        [doc.topAnchor constraintEqualToAnchor:sv.contentView.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor constant:32],
        [content.trailingAnchor constraintLessThanOrEqualToAnchor:doc.trailingAnchor constant:-32],
        fill, maxW,
        [content.topAnchor constraintEqualToAnchor:doc.topAnchor constant:20],
        [doc.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:32],
    ]];
    return sv;
}

static NSStackView *GMPageStack(NSArray *views){
    NSStackView *st = [NSStackView stackViewWithViews:views];
    st.orientation = NSUserInterfaceLayoutOrientationVertical;
    st.alignment = NSLayoutAttributeLeading;
    st.spacing = 20;
    for (NSView *v in views) {
        if ([v isKindOfClass:[NSBox class]] || [v isKindOfClass:[NSStackView class]])
            [v.widthAnchor constraintEqualToAnchor:st.widthAnchor].active = YES;
    }
    return st;
}

#pragma mark - 侧边栏数据

typedef struct { const char *ident; const char *zh; const char *sym; const char *fallback; BOOL group; } GMItem;
static const GMItem kItems[] = {
    { "g.write",     "写作",     NULL, NULL, YES },
    { "write",       "写作工具", "apple.intelligence", "wand.and.stars", NO },
    { "shortcuts",   "快捷操作", "command", "keyboard", NO },
    { "g.settings",  "设置",     NULL, NULL, YES },
    { "providers",   "服务商",   "server.rack", "network", NO },
    { "general",     "通用",     "gearshape", "gear", NO },
    { "diagnostics", "诊断",     "stethoscope", "checkmark.seal", NO },
};
static const NSInteger kItemCount = sizeof(kItems) / sizeof(kItems[0]);

#pragma mark - GMShell

@interface GMShell : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate, NSWindowDelegate, NSMenuItemValidation, NSToolbarItemValidation>
@property (nonatomic, strong) NSWindow *win;
@property (nonatomic, weak) id ctl;
@property (nonatomic, strong) NSTextView *editor;
@property (nonatomic, strong) NSSplitViewController *split;
@property (nonatomic, strong) NSSplitViewItem *sidebarItem;
@property (nonatomic, strong) NSTableView *sidebar;
@property (nonatomic, strong) NSView *detail;
@property (nonatomic, strong) NSMutableDictionary<NSString*, NSView*> *panes;
@property (nonatomic, copy) NSString *current;
@property (nonatomic, strong) NSTextField *writeSub;
// 服务商
@property (nonatomic, strong) NSTableView *plist;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary*> *items;
@property (nonatomic, copy) NSString *activeId;
@property (nonatomic, assign) NSInteger selected;
@property (nonatomic, strong) NSTextField *fName, *fBase, *fPath, *fModel, *fIPs;
@property (nonatomic, strong) NSSecureTextField *fKey;
@property (nonatomic, strong) NSTextField *fKeyPlain;
@property (nonatomic, strong) NSButton *btnReveal, *cbNoThink, *btnTest, *btnActive, *btnAdvanced;
@property (nonatomic, strong) NSGridView *form;
@property (nonatomic, strong) NSImageView *pStatusIcon;
@property (nonatomic, strong) NSTextField *pStatus;
@property (nonatomic, strong) NSSegmentedControl *addRemove;
// 通用
@property (nonatomic, strong) NSSwitch *swAutostart, *swAutoCopy;
@property (nonatomic, strong) NSPopUpButton *popLang;
@property (nonatomic, strong) NSImageView *axIcon;
@property (nonatomic, strong) NSTextField *axText;
@property (nonatomic, strong) NSButton *axButton;
// 诊断
@property (nonatomic, strong) NSTextField *dSummary;
@property (nonatomic, strong) NSStackView *dResults;
@property (nonatomic, strong) NSTextView *dLog;
@property (nonatomic, strong) NSButton *btnDoctor;
@property (nonatomic, strong) NSProgressIndicator *dSpin;
@property (nonatomic, assign) BOOL doctorRunning;
// 紧凑（隐形）模式
@property (nonatomic, assign) BOOL compact;
@property (nonatomic, assign) NSRect savedFrame;
@end

static GMShell *gShell = nil;
static void GMShellSetCompactInternal(BOOL on, NSRect frame);

static NSWindowStyleMask GMShellMask(void){
    return NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
           NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView;
}

@implementation GMShell

- (void)buildWithEditor:(NSTextView *)tv controller:(id)ctl {
    self.editor = tv; self.ctl = ctl;
    self.panes = [NSMutableDictionary dictionary];
    self.selected = -1;

    self.win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 980, 640)
                                           styleMask:GMShellMask()
                                             backing:NSBackingStoreBuffered defer:NO];
    self.win.title = GMTr(@"Apple 智能（Intel）");
    self.win.releasedWhenClosed = NO;
    self.win.delegate = self;
    self.win.contentMinSize = NSMakeSize(760, 480);
    self.win.toolbarStyle = NSWindowToolbarStyleUnified;
    self.win.titlebarSeparatorStyle = NSTitlebarSeparatorStyleAutomatic;
    [self.win center];

    // 侧边栏
    NSViewController *sideVC = [NSViewController new];
    NSScrollView *ssv = [NSScrollView new];
    ssv.hasVerticalScroller = YES; ssv.autohidesScrollers = YES;
    ssv.drawsBackground = NO; ssv.borderType = NSNoBorder;
    self.sidebar = [NSTableView new];
    self.sidebar.style = NSTableViewStyleSourceList;
    self.sidebar.headerView = nil;
    self.sidebar.rowSizeStyle = NSTableViewRowSizeStyleDefault;
    self.sidebar.floatsGroupRows = NO;
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"c"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [self.sidebar addTableColumn:col];
    self.sidebar.dataSource = self; self.sidebar.delegate = self;
    self.sidebar.accessibilityLabel = GMTr(@"功能");
    ssv.documentView = self.sidebar;
    sideVC.view = ssv;

    // 内容区
    NSViewController *detailVC = [NSViewController new];
    self.detail = [NSView new];
    detailVC.view = self.detail;
    [self.detail.widthAnchor constraintGreaterThanOrEqualToConstant:520].active = YES;

    self.split = [NSSplitViewController new];
    self.sidebarItem = [NSSplitViewItem sidebarWithViewController:sideVC];
    self.sidebarItem.minimumThickness = 190;
    self.sidebarItem.maximumThickness = 280;
    self.sidebarItem.canCollapse = YES;
    [self.split addSplitViewItem:self.sidebarItem];
    NSSplitViewItem *main = [NSSplitViewItem splitViewItemWithViewController:detailVC];
    [self.split addSplitViewItem:main];
    self.split.splitView.dividerStyle = NSSplitViewDividerStyleThin;
    self.split.splitView.autosaveName = @"GMShellSplit";
    self.win.contentViewController = self.split;
    [self.win setContentSize:NSMakeSize(980, 640)];
    [self.win center];
    [self.win setFrameAutosaveName:@"GMShellMain"];

    NSToolbar *tb = [[NSToolbar alloc] initWithIdentifier:@"GMShellToolbar"];
    tb.delegate = self;
    tb.displayMode = NSToolbarDisplayModeIconOnly;
    tb.allowsUserCustomization = NO;
    self.win.toolbar = tb;

    [self addPane:@"write" view:[self buildWrite]];
    [self addPane:@"shortcuts" view:[self buildShortcuts]];
    [self addPane:@"providers" view:[self buildProviders]];
    [self addPane:@"general" view:[self buildGeneral]];
    [self addPane:@"diagnostics" view:[self buildDiagnostics]];

    [self.sidebar reloadData];
    NSString *last = [[NSUserDefaults standardUserDefaults] stringForKey:@"GMShellPane"];
    [self select:last.length && self.panes[last] ? last : @"write"];
    [self reloadProviders];

    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification object:self.win
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){ [self refreshGeneral]; [self refreshWriteDisclosure]; }];
}

- (void)addPane:(NSString *)ident view:(NSView *)v {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [self.detail addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [v.leadingAnchor constraintEqualToAnchor:self.detail.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:self.detail.trailingAnchor],
        [v.topAnchor constraintEqualToAnchor:self.detail.safeAreaLayoutGuide.topAnchor],
        [v.bottomAnchor constraintEqualToAnchor:self.detail.bottomAnchor],
    ]];
    v.hidden = YES;
    self.panes[ident] = v;
}

- (NSInteger)rowForIdent:(NSString *)ident {
    for (NSInteger i = 0; i < kItemCount; i++) if ([ident isEqualToString:@(kItems[i].ident)]) return i;
    return -1;
}

- (void)select:(NSString *)ident {
    if (!self.panes[ident]) return;
    for (NSString *k in self.panes) self.panes[k].hidden = ![k isEqualToString:ident];
    self.current = ident;
    NSInteger r = [self rowForIdent:ident];
    if (r >= 0 && self.sidebar.selectedRow != r)
        [self.sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:r] byExtendingSelection:NO];
    if (!self.compact) [[NSUserDefaults standardUserDefaults] setObject:ident forKey:@"GMShellPane"];
    [self.win.toolbar validateVisibleItems];
    [self updateToolbarVisibility];
    if ([ident isEqualToString:@"write"]) [self.win makeFirstResponder:self.editor];
    if ([ident isEqualToString:@"general"]) [self refreshGeneral];
    if ([ident isEqualToString:@"diagnostics"]) [self refreshLog];
}

- (void)updateToolbarVisibility {
    BOOL w = [self.current isEqualToString:@"write"];
    for (NSToolbarItem *it in self.win.toolbar.items) {
        if ([it.itemIdentifier hasPrefix:@"gm.write."]) {
            if (@available(macOS 15.0, *)) it.hidden = !w;
        }
    }
}

#pragma mark 工具栏

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)tb {
    return @[NSToolbarToggleSidebarItemIdentifier, NSToolbarSidebarTrackingSeparatorItemIdentifier,
             NSToolbarFlexibleSpaceItemIdentifier, @"gm.write.undo", @"gm.write.tools"];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)tb {
    return [self toolbarDefaultItemIdentifiers:tb];
}
- (NSToolbarItem *)toolbar:(NSToolbar *)tb itemForItemIdentifier:(NSToolbarItemIdentifier)ident willBeInsertedIntoToolbar:(BOOL)flag {
    NSToolbarItem *it = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
    if ([ident isEqualToString:@"gm.write.tools"]) {
        it.label = GMTr(@"写作工具");
        it.toolTip = GMTr(@"打开写作工具（⌘9 可在任意 App 中使用）");
        it.image = GMSym(@"apple.intelligence", @"wand.and.stars", it.label);
        it.target = self.ctl; it.action = NSSelectorFromString(@"showWT:");
        it.bordered = YES;
        if (@available(macOS 26.0, *)) { /* 主要动作：系统会用强调样式 */ it.style = NSToolbarItemStyleProminent; }
    } else if ([ident isEqualToString:@"gm.write.undo"]) {
        it.label = GMTr(@"撤销改写");
        it.toolTip = GMTr(@"撤销上一次改写");
        it.image = GMSym(@"arrow.uturn.backward", nil, it.label);
        it.target = self.ctl; it.action = NSSelectorFromString(@"undoRewrite:");
        it.bordered = YES;
    }
    return it;
}
- (BOOL)validateToolbarItem:(NSToolbarItem *)item { return YES; }

#pragma mark 侧边栏 table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    if (tv == self.sidebar) return kItemCount;
    return (NSInteger)self.items.count;
}
- (BOOL)tableView:(NSTableView *)tv isGroupRow:(NSInteger)row {
    return tv == self.sidebar && kItems[row].group;
}
- (BOOL)tableView:(NSTableView *)tv shouldSelectRow:(NSInteger)row {
    if (tv == self.sidebar) return !kItems[row].group;
    return YES;
}
- (CGFloat)tableView:(NSTableView *)tv heightOfRow:(NSInteger)row {
    if (tv == self.sidebar) return kItems[row].group ? 28 : 30;
    return 40;
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    if (tv == self.sidebar) {
        GMItem it = kItems[row];
        NSString *ident = it.group ? @"group" : @"item";
        NSTableCellView *cell = [tv makeViewWithIdentifier:ident owner:self];
        if (!cell) {
            cell = [NSTableCellView new];
            cell.identifier = ident;
            NSTextField *t = GMLabel(@"", nil, nil);
            t.lineBreakMode = NSLineBreakByTruncatingTail;
            [cell addSubview:t]; cell.textField = t;
            if (!it.group) {
                NSImageView *iv = [NSImageView new];
                iv.translatesAutoresizingMaskIntoConstraints = NO;
                iv.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular];
                [cell addSubview:iv]; cell.imageView = iv;
                [NSLayoutConstraint activateConstraints:@[
                    [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
                    [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
                    [iv.widthAnchor constraintEqualToConstant:20],
                    [t.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:7],
                ]];
            } else {
                [t.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2].active = YES;
            }
            [t.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor].active = YES;
            [t.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-4].active = YES;
        }
        cell.textField.stringValue = GMTr(@(it.zh));
        if (it.group) {
            cell.textField.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
            cell.textField.textColor = NSColor.secondaryLabelColor;
        } else {
            cell.textField.font = [NSFont systemFontOfSize:13];
            cell.imageView.image = GMSym(@(it.sym), it.fallback ? @(it.fallback) : nil, cell.textField.stringValue);
            cell.imageView.contentTintColor = NSColor.controlAccentColor;
        }
        return cell;
    }
    // 服务商列表
    if (row < 0 || row >= (NSInteger)self.items.count) return nil;
    NSDictionary *p = self.items[row];
    NSTableCellView *cell = [tv makeViewWithIdentifier:@"prov" owner:self];
    NSTextField *sub = nil;
    if (!cell) {
        cell = [NSTableCellView new];
        cell.identifier = @"prov";
        NSImageView *iv = [NSImageView new];
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:iv]; cell.imageView = iv;
        NSTextField *t = GMLabel(@"", [NSFont systemFontOfSize:13], nil);
        t.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:t]; cell.textField = t;
        sub = GMLabel(@"", [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor);
        sub.identifier = @"sub"; sub.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:sub];
        [NSLayoutConstraint activateConstraints:@[
            [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6],
            [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [iv.widthAnchor constraintEqualToConstant:16],
            [t.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:8],
            [t.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-6],
            [t.topAnchor constraintEqualToAnchor:cell.topAnchor constant:4],
            [sub.leadingAnchor constraintEqualToAnchor:t.leadingAnchor],
            [sub.trailingAnchor constraintLessThanOrEqualToAnchor:cell.trailingAnchor constant:-6],
            [sub.topAnchor constraintEqualToAnchor:t.bottomAnchor constant:1],
        ]];
    } else {
        for (NSView *v in cell.subviews) if ([v.identifier isEqual:@"sub"]) sub = (NSTextField *)v;
    }
    BOOL active = [self.activeId isEqual:p[@"id"]];
    cell.textField.stringValue = p[@"name"] ?: @"";
    sub.stringValue = active ? [NSString stringWithFormat:@"%@ · %@", GMTr(@"当前使用"), p[@"model"] ?: @""] : (p[@"model"] ?: @"");
    // 不只靠颜色：当前项用实心勾 + 文字「当前使用」
    cell.imageView.image = active ? GMSym(@"checkmark.circle.fill", nil, GMTr(@"当前使用")) : GMSym(@"circle", nil, nil);
    cell.imageView.contentTintColor = active ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)n {
    NSTableView *tv = n.object;
    if (tv == self.sidebar) {
        NSInteger r = tv.selectedRow;
        if (r >= 0 && !kItems[r].group) [self select:@(kItems[r].ident)];
    } else if (tv == self.plist) {
        NSInteger r = tv.selectedRow;
        if (r >= 0) [self loadForm:r];
        [self updateProviderButtons];
    }
}

#pragma mark - 写作工具页

- (NSView *)buildWrite {
    NSView *root = [NSView new];
    NSTextField *sub = nil;
    NSStackView *hdr = GMHeader(GMTr(@"写作工具"), &sub, @"");
    self.writeSub = sub;
    [root addSubview:hdr];

    NSScrollView *sv = [NSScrollView new];
    sv.hasVerticalScroller = YES; sv.autohidesScrollers = YES;
    sv.borderType = NSNoBorder; sv.drawsBackground = NO;
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextView *tv = self.editor;
    tv.frame = NSMakeRect(0, 0, 600, 400);
    tv.minSize = NSMakeSize(0, 0);
    tv.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    tv.verticallyResizable = YES; tv.horizontallyResizable = NO;
    tv.autoresizingMask = NSViewWidthSizable;
    tv.textContainer.widthTracksTextView = YES;
    tv.textContainerInset = NSMakeSize(14, 14);
    tv.drawsBackground = NO;
    tv.textColor = NSColor.textColor;
    tv.allowsUndo = YES;
    tv.accessibilityLabel = GMTr(@"正文");
    sv.documentView = tv;

    // 卡片：圆角 + 细边框，让“这是你的文字”这件事一眼可见
    NSBox *card = [NSBox new];
    card.boxType = NSBoxCustom; card.cornerRadius = 10; card.borderWidth = 1;
    card.borderColor = NSColor.separatorColor;
    card.fillColor = NSColor.textBackgroundColor;
    card.contentViewMargins = NSZeroSize;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:sv];
    [root addSubview:card];

    [NSLayoutConstraint activateConstraints:@[
        [hdr.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:32],
        [hdr.trailingAnchor constraintLessThanOrEqualToAnchor:root.trailingAnchor constant:-32],
        [hdr.topAnchor constraintEqualToAnchor:root.topAnchor constant:20],
        [sub.widthAnchor constraintLessThanOrEqualToConstant:680],
        [card.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:32],
        [card.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-32],
        [card.topAnchor constraintEqualToAnchor:hdr.bottomAnchor constant:16],
        [card.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-24],
        [sv.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:1],
        [sv.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-1],
        [sv.topAnchor constraintEqualToAnchor:card.topAnchor constant:4],
        [sv.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-4],
    ]];
    [self refreshWriteDisclosure];
    return root;
}

- (void)refreshWriteDisclosure {
    NSDictionary *p = GMBridgeActiveProvider();
    NSString *who = p ? [NSString stringWithFormat:@"%@ · %@", p[@"name"] ?: p[@"id"] ?: @"", p[@"model"] ?: @""] : GMTr(@"未配置");
    self.writeSub.stringValue = [NSString stringWithFormat:GMTr(@"选中文字后点工具栏的「写作工具」，或在任意 App 里按 ⌘9。结果由 %@ 生成，可能有误，可随时撤销。"), who];
}

#pragma mark - 快捷操作页

- (NSView *)buildShortcuts {
    NSView *grab = GMRow(GMTile(@"text.cursor", @"character.cursor.ibeam", NSColor.systemBlueColor),
                         GMTr(@"改写任意 App 里的选中文字"),
                         GMTr(@"在备忘录、邮件、浏览器等任意 App 中选中文字后按下，面板会在原地浮出，结果直接写回。"),
                         GMKeycap(@"⌘9"));
    NSButton *bClip = GMButton(GMTr(@"现在打开"), self.ctl, NSSelectorFromString(@"clipWT:"));
    NSView *clip = GMRow(GMTile(@"doc.on.clipboard", @"clipboard", NSColor.systemIndigoColor),
                         GMTr(@"用剪贴板文字打开写作工具"),
                         [NSString stringWithFormat:@"%@  ⌃⌥⌘W", GMTr(@"把剪贴板里的文字放进编辑区并打开面板。")],
                         bClip);
    NSButton *bUndo = GMButton(GMTr(@"撤销"), self.ctl, NSSelectorFromString(@"undoRewrite:"));
    NSView *undo = GMRow(GMTile(@"arrow.uturn.backward", nil, NSColor.systemOrangeColor),
                         GMTr(@"撤销上一次改写"),
                         GMTr(@"最多可以回退 5 步。"),
                         bUndo);

    NSButton *bKb = GMButton(GMTr(@"键盘设置…"), self, @selector(actOpenKeyboardSettings:));
    NSView *svc = GMRow(GMTile(@"contextualmenu.and.cursorarrow", @"cursorarrow.click", NSColor.systemPurpleColor),
                        GMTr(@"右键 → 服务"),
                        GMTr(@"直接改写、直接摘要、直接翻译、直接校对、改写并复制结果，1 秒级完成，不打开面板。可以在键盘设置里给它们设快捷键。"),
                        bKb);

    NSStackView *page = GMPageStack(@[
        GMHeader(GMTr(@"快捷操作"), NULL, GMTr(@"不用切换 App 就能用写作工具。")),
        GMSection(GMTr(@"全局")), GMGroup(@[grab, clip, undo]),
        GMSection(GMTr(@"系统服务")), GMGroup(@[svc]),
    ]);
    [page setCustomSpacing:8 afterView:page.arrangedSubviews[1]];
    [page setCustomSpacing:8 afterView:page.arrangedSubviews[3]];
    return GMScrollPage(page);
}

- (void)actOpenKeyboardSettings:(id)s {
    NSURL *u = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.Keyboard-Settings.extension"];
    if (![[NSWorkspace sharedWorkspace] openURL:u])
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:@"/System/Applications/System Settings.app"]];
}

#pragma mark - 服务商页

static NSArray *GMPresets(void){
    return @[
        @[@"千问 Token Plan", @"https://token-plan.cn-beijing.maas.aliyuncs.com", @"/compatible-mode/v1/chat/completions", @"qwen3.8-flash", @YES],
        @[@"OpenAI", @"https://api.openai.com", @"/v1/chat/completions", @"gpt-4o-mini", @YES],
        @[@"OpenRouter", @"https://openrouter.ai/api", @"/v1/chat/completions", @"openai/gpt-4o-mini", @YES],
        @[@"DeepSeek", @"https://api.deepseek.com", @"/v1/chat/completions", @"deepseek-chat", @YES],
        @[@"Ollama（本地）", @"http://127.0.0.1:11434", @"/v1/chat/completions", @"llama3.1", @NO],
        @[@"LiteLLM（本地）", @"http://127.0.0.1:4000", @"/v1/chat/completions", @"gpt-4o-mini", @YES],
        @[@"new-api / one-api（本地）", @"http://127.0.0.1:3000", @"/v1/chat/completions", @"gpt-4o-mini", @YES],
    ];
}

- (NSTextField *)field:(NSString *)placeholder {
    NSTextField *f = [NSTextField textFieldWithString:@""];
    f.placeholderString = placeholder;
    f.translatesAutoresizingMaskIntoConstraints = NO;
    [f.widthAnchor constraintGreaterThanOrEqualToConstant:260].active = YES;
    return f;
}
- (NSTextField *)formLabel:(NSString *)s {
    NSTextField *l = GMLabel(s, [NSFont systemFontOfSize:13], NSColor.labelColor);
    l.alignment = NSTextAlignmentRight;
    return l;
}

- (NSView *)buildProviders {
    // 左：列表
    NSScrollView *lsv = [NSScrollView new];
    lsv.hasVerticalScroller = YES; lsv.autohidesScrollers = YES;
    lsv.borderType = NSNoBorder; lsv.drawsBackground = NO;
    lsv.translatesAutoresizingMaskIntoConstraints = NO;
    self.plist = [NSTableView new];
    self.plist.style = NSTableViewStyleInset;
    self.plist.headerView = nil;
    self.plist.backgroundColor = NSColor.clearColor;
    NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:@"p"];
    c.resizingMask = NSTableColumnAutoresizingMask;
    [self.plist addTableColumn:c];
    self.plist.dataSource = self; self.plist.delegate = self;
    self.plist.accessibilityLabel = GMTr(@"服务商列表");
    self.plist.target = self; self.plist.doubleAction = @selector(actSetActive:);
    lsv.documentView = self.plist;

    NSBox *listBox = GMGroup(@[lsv]);
    [lsv.heightAnchor constraintGreaterThanOrEqualToConstant:220].active = YES;

    self.addRemove = [NSSegmentedControl segmentedControlWithImages:@[
        GMSym(@"plus", nil, GMTr(@"新增")), GMSym(@"minus", nil, GMTr(@"删除"))]
        trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(actAddRemove:)];
    [self.addRemove setToolTip:GMTr(@"新增") forSegment:0];
    [self.addRemove setToolTip:GMTr(@"删除") forSegment:1];
    self.addRemove.translatesAutoresizingMaskIntoConstraints = NO;

    NSPopUpButton *preset = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    preset.translatesAutoresizingMaskIntoConstraints = NO;
    [preset addItemWithTitle:GMTr(@"从预设添加")];
    NSInteger tag = 0;
    for (NSArray *p in GMPresets()) {
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:p[0] action:@selector(actPreset:) keyEquivalent:@""];
        mi.target = self; mi.tag = tag++;
        [preset.menu addItem:mi];
    }
    NSStackView *listBar = [NSStackView stackViewWithViews:@[self.addRemove, preset]];
    listBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    listBar.spacing = 8;

    NSStackView *left = [NSStackView stackViewWithViews:@[listBox, listBar]];
    left.orientation = NSUserInterfaceLayoutOrientationVertical;
    left.alignment = NSLayoutAttributeLeading;
    left.spacing = 8;
    left.translatesAutoresizingMaskIntoConstraints = NO;
    [listBox.widthAnchor constraintEqualToAnchor:left.widthAnchor].active = YES;
    [left.widthAnchor constraintEqualToConstant:230].active = YES;

    // 右：表单
    self.fName = [self field:GMTr(@"例如：千问")];
    self.fBase = [self field:@"https://api.example.com"];
    self.fModel = [self field:@"gpt-4o-mini"];
    self.fKey = [NSSecureTextField textFieldWithString:@""];
    self.fKey.placeholderString = GMTr(@"只保存在这台 Mac 上");
    self.fKey.translatesAutoresizingMaskIntoConstraints = NO;
    self.fKeyPlain = [self field:self.fKey.placeholderString];
    self.fKeyPlain.hidden = YES;
    self.btnReveal = [NSButton buttonWithImage:GMSym(@"eye", nil, GMTr(@"显示密钥")) target:self action:@selector(actReveal:)];
    self.btnReveal.bordered = NO;
    self.btnReveal.toolTip = GMTr(@"显示密钥");
    self.btnReveal.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *keyRow = [NSStackView stackViewWithViews:@[self.fKey, self.fKeyPlain, self.btnReveal]];
    keyRow.orientation = NSUserInterfaceLayoutOrientationHorizontal; keyRow.spacing = 6;
    [self.fKey.widthAnchor constraintGreaterThanOrEqualToConstant:232].active = YES;
    [self.fKeyPlain.widthAnchor constraintEqualToAnchor:self.fKey.widthAnchor].active = YES;

    self.fPath = [self field:@"/v1/chat/completions"];
    self.fIPs = [self field:GMTr(@"可留空，多个用逗号分隔")];
    self.cbNoThink = [NSButton checkboxWithTitle:GMTr(@"关闭思维链（更快，推荐）") target:nil action:nil];

    self.btnAdvanced = [NSButton buttonWithTitle:GMTr(@"高级") target:self action:@selector(actToggleAdvanced:)];
    self.btnAdvanced.bezelStyle = NSBezelStyleDisclosure;
    [self.btnAdvanced setButtonType:NSButtonTypePushOnPushOff];
    self.btnAdvanced.title = @"";
    NSTextField *advLbl = GMLabel(GMTr(@"高级"), [NSFont systemFontOfSize:13], NSColor.secondaryLabelColor);
    NSStackView *adv = [NSStackView stackViewWithViews:@[self.btnAdvanced, advLbl]];
    adv.spacing = 4;

    self.form = [NSGridView gridViewWithViews:@[
        @[[self formLabel:GMTr(@"名称")], self.fName],
        @[[self formLabel:@"Base URL"], self.fBase],
        @[[self formLabel:@"API Key"], keyRow],
        @[[self formLabel:GMTr(@"模型")], self.fModel],
        @[NSGridCell.emptyContentView, self.cbNoThink],
        @[NSGridCell.emptyContentView, adv],
        @[[self formLabel:GMTr(@"请求路径")], self.fPath],
        @[[self formLabel:GMTr(@"备用 IP")], self.fIPs],
    ]];
    self.form.translatesAutoresizingMaskIntoConstraints = NO;
    self.form.rowSpacing = 10; self.form.columnSpacing = 10;
    self.form.rowAlignment = NSGridRowAlignmentFirstBaseline;
    [self.form columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    [self.form rowAtIndex:6].hidden = YES;
    [self.form rowAtIndex:7].hidden = YES;

    self.btnTest = GMButton(GMTr(@"测试连接"), self, @selector(actTest:));
    self.btnActive = GMButton(GMTr(@"设为当前"), self, @selector(actSetActive:));
    NSButton *bSave = GMButton(GMTr(@"保存"), self, @selector(actSave:));
    bSave.keyEquivalent = @"\r";
    NSView *spacer = [NSView new];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *actions = [NSStackView stackViewWithViews:@[self.btnTest, spacer, self.btnActive, bSave]];
    actions.orientation = NSUserInterfaceLayoutOrientationHorizontal; actions.spacing = 8;
    actions.translatesAutoresizingMaskIntoConstraints = NO;

    self.pStatusIcon = [NSImageView new];
    self.pStatusIcon.translatesAutoresizingMaskIntoConstraints = NO;
    self.pStatus = GMWrap(@"", [NSFont systemFontOfSize:12], NSColor.secondaryLabelColor);
    NSStackView *status = [NSStackView stackViewWithViews:@[self.pStatusIcon, self.pStatus]];
    status.alignment = NSLayoutAttributeFirstBaseline; status.spacing = 6;
    status.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *formInner = [NSStackView stackViewWithViews:@[self.form, actions, status]];
    formInner.orientation = NSUserInterfaceLayoutOrientationVertical;
    formInner.alignment = NSLayoutAttributeLeading;
    formInner.spacing = 16;
    formInner.edgeInsets = NSEdgeInsetsMake(18, 18, 18, 18);
    formInner.translatesAutoresizingMaskIntoConstraints = NO;
    [actions.widthAnchor constraintEqualToAnchor:self.form.widthAnchor].active = YES;
    [status.widthAnchor constraintLessThanOrEqualToAnchor:self.form.widthAnchor].active = YES;
    NSBox *formBox = GMGroup(@[formInner]);

    NSStackView *cols = [NSStackView stackViewWithViews:@[left, formBox]];
    cols.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    cols.alignment = NSLayoutAttributeTop;
    cols.spacing = 20;
    cols.translatesAutoresizingMaskIntoConstraints = NO;
    [listBox.heightAnchor constraintEqualToAnchor:formBox.heightAnchor].active = YES;

    NSStackView *page = GMPageStack(@[
        GMHeader(GMTr(@"服务商"), NULL, GMTr(@"任意 OpenAI 兼容服务都可以。密钥只保存在这台 Mac 上，保存后下一次请求立即生效。")),
        cols,
    ]);
    return GMScrollPage(page);
}

- (void)actReveal:(id)s {
    BOOL show = self.fKeyPlain.hidden;
    if (show) self.fKeyPlain.stringValue = self.fKey.stringValue;
    else self.fKey.stringValue = self.fKeyPlain.stringValue;
    self.fKeyPlain.hidden = !show; self.fKey.hidden = show;
    self.btnReveal.image = GMSym(show ? @"eye.slash" : @"eye", nil, show ? GMTr(@"隐藏密钥") : GMTr(@"显示密钥"));
    self.btnReveal.toolTip = show ? GMTr(@"隐藏密钥") : GMTr(@"显示密钥");
}
- (NSString *)keyValue { return self.fKeyPlain.hidden ? self.fKey.stringValue : self.fKeyPlain.stringValue; }
- (void)setKeyValue:(NSString *)v { self.fKey.stringValue = v ?: @""; self.fKeyPlain.stringValue = v ?: @""; }

- (void)actToggleAdvanced:(id)s {
    BOOL on = self.btnAdvanced.state == NSControlStateValueOn;
    [self.form rowAtIndex:6].hidden = !on;
    [self.form rowAtIndex:7].hidden = !on;
}

- (void)setPStatus:(NSString *)text kind:(int)kind {
    // kind: 0 普通 1 成功 2 失败 3 进行中 —— 图标形状 + 文字，不只靠颜色
    NSString *sym = kind == 1 ? @"checkmark.circle.fill" : kind == 2 ? @"exclamationmark.triangle.fill" : kind == 3 ? @"clock" : @"info.circle";
    NSColor *c = kind == 1 ? NSColor.systemGreenColor : kind == 2 ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    self.pStatusIcon.image = GMSym(sym, nil, nil);
    self.pStatusIcon.contentTintColor = c;
    self.pStatus.stringValue = text ?: @"";
    self.pStatus.textColor = kind == 2 ? NSColor.labelColor : NSColor.secondaryLabelColor;
}

- (void)reloadProviders {
    self.items = [NSMutableArray array];
    self.activeId = @"";
    NSData *d = [NSData dataWithContentsOfFile:GMCfgPath()];
    if (d) {
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        if ([root isKindOfClass:[NSDictionary class]]) {
            self.activeId = root[@"active"] ?: @"";
            for (NSDictionary *p in root[@"providers"])
                if ([p isKindOfClass:[NSDictionary class]]) [self.items addObject:[p mutableCopy]];
        }
    }
    [self.plist reloadData];
    NSInteger row = 0;
    for (NSInteger i = 0; i < (NSInteger)self.items.count; i++)
        if ([self.items[i][@"id"] isEqual:self.activeId]) { row = i; break; }
    if (self.items.count) {
        [self.plist selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        [self loadForm:row];
        [self setPStatus:GMTr(@"填好后点「测试连接」确认能连上，再点「保存」。") kind:0];
    } else {
        [self clearForm];
        [self setPStatus:GMTr(@"还没有服务商。点 + 新增，或从预设添加。") kind:0];
    }
    [self updateProviderButtons];
}

- (void)updateProviderButtons {
    BOOL has = self.selected >= 0 && self.selected < (NSInteger)self.items.count;
    [self.addRemove setEnabled:has forSegment:1];
    BOOL isActive = has && [self.activeId isEqual:self.items[self.selected][@"id"]];
    self.btnActive.enabled = has && !isActive;
    self.btnActive.title = isActive ? GMTr(@"当前使用中") : GMTr(@"设为当前");
}

- (void)clearForm {
    for (NSTextField *f in @[self.fName, self.fBase, self.fPath, self.fModel, self.fIPs]) f.stringValue = @"";
    [self setKeyValue:@""];
    self.cbNoThink.state = NSControlStateValueOn;
    self.selected = -1;
}

- (void)loadForm:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.items.count) { [self clearForm]; return; }
    NSDictionary *p = self.items[row];
    self.fName.stringValue = p[@"name"] ?: @"";
    self.fBase.stringValue = p[@"base_url"] ?: @"";
    self.fPath.stringValue = p[@"chat_path"] ?: @"/v1/chat/completions";
    [self setKeyValue:p[@"api_key"]];
    self.fModel.stringValue = p[@"model"] ?: @"";
    NSArray *ips = p[@"ips"];
    self.fIPs.stringValue = [ips isKindOfClass:[NSArray class]] ? [ips componentsJoinedByString:@","] : @"";
    self.cbNoThink.state = [p[@"no_think"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    self.selected = row;
}

- (NSDictionary *)formDict {
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    NSString *ident = (self.selected >= 0 && self.selected < (NSInteger)self.items.count) ? self.items[self.selected][@"id"] : nil;
    p[@"id"] = ident.length ? ident : [[NSUUID UUID].UUIDString substringToIndex:8];
    p[@"name"] = self.fName.stringValue.length ? self.fName.stringValue : GMTr(@"未命名");
    p[@"base_url"] = [self.fBase.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    p[@"chat_path"] = self.fPath.stringValue.length ? self.fPath.stringValue : @"/v1/chat/completions";
    p[@"api_key"] = [[self keyValue] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    p[@"model"] = self.fModel.stringValue.length ? self.fModel.stringValue : @"gpt-4o-mini";
    NSMutableArray *ips = [NSMutableArray array];
    for (NSString *s in [self.fIPs.stringValue componentsSeparatedByString:@","]) {
        NSString *t = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (t.length) [ips addObject:t];
    }
    p[@"ips"] = ips;
    p[@"no_think"] = @(self.cbNoThink.state == NSControlStateValueOn);
    return p;
}

- (void)writeConfig {
    NSDictionary *root = @{ @"active": self.activeId ?: @"", @"providers": self.items };
    NSData *d = [NSJSONSerialization dataWithJSONObject:root
                                               options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    [[NSFileManager defaultManager] createDirectoryAtPath:GMHome() withIntermediateDirectories:YES attributes:nil error:NULL];
    [d writeToFile:GMCfgPath() atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@(0600)} ofItemAtPath:GMCfgPath() error:NULL];
    [self refreshWriteDisclosure];
}

- (void)selectProviderRow:(NSInteger)row {
    [self.plist reloadData];
    if (row >= 0 && row < (NSInteger)self.items.count) {
        [self.plist selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        [self loadForm:row];
    } else [self clearForm];
    [self updateProviderButtons];
}

- (void)actAddRemove:(NSSegmentedControl *)s {
    if (s.selectedSegment == 0) [self actAdd:nil]; else [self actDelete:nil];
}

- (void)actAdd:(id)s {
    NSMutableDictionary *p = [@{ @"id": [[NSUUID UUID].UUIDString substringToIndex:8],
                                 @"name": GMTr(@"新服务商"), @"base_url": @"https://",
                                 @"chat_path": @"/v1/chat/completions", @"api_key": @"",
                                 @"model": @"gpt-4o-mini", @"ips": @[], @"no_think": @YES } mutableCopy];
    [self.items addObject:p];
    if (!self.activeId.length) self.activeId = p[@"id"];
    [self writeConfig];
    [self selectProviderRow:(NSInteger)self.items.count - 1];
    [self.win makeFirstResponder:self.fName];
    [self setPStatus:GMTr(@"已新增。填写 Base URL、API Key 和模型后点「保存」。") kind:0];
}

- (void)actDelete:(id)s {
    if (self.selected < 0 || self.selected >= (NSInteger)self.items.count) return;
    NSInteger idx = self.selected;
    NSString *name = self.items[idx][@"name"] ?: @"";
    // 删除不可撤销：用表单 sheet 确认，默认按钮是「取消」
    NSAlert *a = [NSAlert new];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = [NSString stringWithFormat:GMTr(@"删除「%@」？"), name];
    a.informativeText = GMTr(@"它的 API Key 也会从这台 Mac 上移除。");
    NSButton *del = [a addButtonWithTitle:GMTr(@"删除")];
    del.hasDestructiveAction = YES;
    NSButton *cancel = [a addButtonWithTitle:GMTr(@"取消")];
    cancel.keyEquivalent = @"\r"; del.keyEquivalent = @"";
    [a beginSheetModalForWindow:self.win completionHandler:^(NSModalResponse r) {
        if (r != NSAlertFirstButtonReturn) return;
        if (idx >= (NSInteger)self.items.count) return;
        NSString *dead = self.items[idx][@"id"];
        [self.items removeObjectAtIndex:idx];
        if ([self.activeId isEqual:dead]) self.activeId = self.items.count ? self.items.firstObject[@"id"] : @"";
        [self writeConfig];
        [self selectProviderRow:MIN(idx, (NSInteger)self.items.count - 1)];
        [self setPStatus:[NSString stringWithFormat:GMTr(@"已删除「%@」。"), name] kind:0];
    }];
}

- (void)actSetActive:(id)s {
    if (self.selected < 0 || self.selected >= (NSInteger)self.items.count) return;
    self.activeId = self.items[self.selected][@"id"];
    [self writeConfig];
    [self selectProviderRow:self.selected];
    [self setPStatus:[NSString stringWithFormat:GMTr(@"之后的请求都会发给「%@」。"), self.items[self.selected][@"name"] ?: @""] kind:1];
}

- (void)actSave:(id)s {
    NSDictionary *p = [self formDict];
    if (![p[@"base_url"] hasPrefix:@"http"]) {
        [self setPStatus:GMTr(@"Base URL 需要以 http:// 或 https:// 开头。") kind:2];
        [self.win makeFirstResponder:self.fBase];
        return;
    }
    NSInteger row = self.selected;
    if (row >= 0 && row < (NSInteger)self.items.count) self.items[row] = [p mutableCopy];
    else { [self.items addObject:[p mutableCopy]]; row = (NSInteger)self.items.count - 1; }
    if (!self.activeId.length) self.activeId = p[@"id"];
    [self writeConfig];
    [self selectProviderRow:row];
    [self setPStatus:GMTr(@"已保存，下一次请求立即生效。") kind:1];
}

- (void)actTest:(id)s {
    NSDictionary *p = [self formDict];
    self.btnTest.enabled = NO;
    self.btnTest.title = GMTr(@"正在测试…");
    [self setPStatus:[NSString stringWithFormat:GMTr(@"正在连接 %@ …"), p[@"base_url"]] kind:3];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
        NSString *err = nil;
        NSString *r = GMBridgeAsk(p, @"Reply with exactly: OK", @"ping", 8, &err);
        NSTimeInterval dt = [NSDate timeIntervalSinceReferenceDate] - t0;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.btnTest.enabled = YES;
            self.btnTest.title = GMTr(@"测试连接");
            if (r) [self setPStatus:[NSString stringWithFormat:GMTr(@"连接正常，用时 %.2f 秒，模型回复「%@」。"), dt, r] kind:1];
            else [self setPStatus:[NSString stringWithFormat:GMTr(@"连不上：%@。请检查 Base URL、API Key 和模型名。"), err ?: GMTr(@"未知错误")] kind:2];
            [self refreshLog];
        });
    });
}

- (void)actPreset:(NSMenuItem *)item {
    NSArray *all = GMPresets();
    if (item.tag < 0 || item.tag >= (NSInteger)all.count) return;
    NSArray *p = all[item.tag];
    [self actAdd:nil];
    self.fName.stringValue = p[0];
    self.fBase.stringValue = p[1];
    self.fPath.stringValue = p[2];
    self.fModel.stringValue = p[3];
    self.cbNoThink.state = [p[4] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    [self.win makeFirstResponder:self.fKeyPlain.hidden ? self.fKey : self.fKeyPlain];
    [self setPStatus:[NSString stringWithFormat:GMTr(@"已套用「%@」预设，填入 API Key 后点「保存」。"), p[0]] kind:0];
}

#pragma mark - 通用页

- (NSView *)buildGeneral {
    self.swAutostart = [NSSwitch new];
    self.swAutostart.target = self; self.swAutostart.action = @selector(actAutostart:);
    self.swAutostart.accessibilityLabel = GMTr(@"登录时打开");
    self.swAutoCopy = [NSSwitch new];
    self.swAutoCopy.target = self; self.swAutoCopy.action = @selector(actAutoCopy:);
    self.swAutoCopy.accessibilityLabel = GMTr(@"结果自动复制到剪贴板");
    self.popLang = [NSPopUpButton new];
    [self.popLang addItemsWithTitles:@[@"中文", @"English"]];
    self.popLang.target = self; self.popLang.action = @selector(actLang:);
    self.popLang.accessibilityLabel = GMTr(@"界面语言");

    NSView *r1 = GMRow(GMTile(@"power", nil, NSColor.systemGrayColor), GMTr(@"登录时打开"),
                       GMTr(@"开机后自动在菜单栏待命，⌘9 随时可用。"), self.swAutostart);
    NSView *r2 = GMRow(GMTile(@"doc.on.doc", nil, NSColor.systemBlueColor), GMTr(@"结果自动复制到剪贴板"),
                       GMTr(@"改写完成后，正文同时放进剪贴板。"), self.swAutoCopy);
    NSView *r3 = GMRow(GMTile(@"globe", nil, NSColor.systemTealColor), GMTr(@"界面语言"),
                       GMTr(@"切换后 App 会自动重新打开。"), self.popLang);

    self.axIcon = [NSImageView new];
    self.axText = GMLabel(@"", [NSFont systemFontOfSize:12], NSColor.secondaryLabelColor);
    self.axButton = GMButton(GMTr(@"授权…"), self.ctl, NSSelectorFromString(@"axAuth:"));
    NSStackView *axAcc = [NSStackView stackViewWithViews:@[self.axIcon, self.axText, self.axButton]];
    axAcc.spacing = 6; axAcc.alignment = NSLayoutAttributeCenterY;
    NSView *r4 = GMRow(GMTile(@"accessibility", @"hand.raised", NSColor.systemBlueColor), GMTr(@"辅助功能"),
                       GMTr(@"只用来读取你在其他 App 里选中的文字并把结果写回，不会上传。"), axAcc);

    NSButton *bFolder = GMButton(GMTr(@"在访达中显示"), self, @selector(actOpenDir:));
    NSView *r5 = GMRow(GMTile(@"folder", nil, NSColor.systemGrayColor), GMTr(@"配置与日志"),
                       @"~/Library/Application Support/AppleIntel", bFolder);

    NSString *ver = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    NSTextField *about = GMWrap([NSString stringWithFormat:GMTr(@"版本 %@ · 非官方项目，与 Apple 无关。面板来自系统自带的写作工具，生成由你配置的服务商完成。"), ver],
                                [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor);

    NSStackView *page = GMPageStack(@[
        GMHeader(GMTr(@"通用"), NULL, GMTr(@"大多数情况下保持默认即可。")),
        GMGroup(@[r1, r2, r3]),
        GMSection(GMTr(@"权限")), GMGroup(@[r4]),
        GMSection(GMTr(@"数据")), GMGroup(@[r5]),
        about,
    ]);
    [page setCustomSpacing:8 afterView:page.arrangedSubviews[2]];
    [page setCustomSpacing:8 afterView:page.arrangedSubviews[4]];
    [about.widthAnchor constraintEqualToAnchor:page.widthAnchor].active = YES;
    return GMScrollPage(page);
}

- (void)refreshGeneral {
    if (!self.swAutostart) return;
    self.swAutostart.state = GMAutostartEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
    self.swAutoCopy.state = AIHGetAutoCopy() ? NSControlStateValueOn : NSControlStateValueOff;
    [self.popLang selectItemAtIndex:[GMLangCode() isEqualToString:@"en"] ? 1 : 0];
    BOOL ax = AXIsProcessTrusted();
    self.axIcon.image = GMSym(ax ? @"checkmark.circle.fill" : @"exclamationmark.circle.fill", nil, nil);
    self.axIcon.contentTintColor = ax ? NSColor.systemGreenColor : NSColor.systemOrangeColor;
    self.axText.stringValue = ax ? GMTr(@"已授权") : GMTr(@"未授权");
    self.axButton.hidden = ax;
}

- (void)actAutostart:(NSSwitch *)s { GMSetupSetAutostart(s.state == NSControlStateValueOn); [self refreshGeneral]; }
- (void)actAutoCopy:(NSSwitch *)s { AIHSetAutoCopy(s.state == NSControlStateValueOn); }
- (void)actLang:(NSPopUpButton *)p {
    NSString *want = p.indexOfSelectedItem == 1 ? @"en" : @"zh";
    if ([want isEqualToString:GMLangCode()]) return;
    SEL sel = NSSelectorFromString(@"toggleLang:");
    if ([self.ctl respondsToSelector:sel]) [NSApp sendAction:sel to:self.ctl from:p];
}
- (void)actOpenDir:(id)s { [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:GMHome()]]; }

#pragma mark - 诊断页

- (NSView *)buildDiagnostics {
    self.dSummary = GMWrap(GMTr(@"还没运行过自检。"), [NSFont systemFontOfSize:13], NSColor.secondaryLabelColor);
    self.dSummary.alignment = NSTextAlignmentLeft;
    self.btnDoctor = GMButton(GMTr(@"运行自检"), self, @selector(actDoctor:));
    self.dSpin = [NSProgressIndicator new];
    self.dSpin.style = NSProgressIndicatorStyleSpinning;
    self.dSpin.controlSize = NSControlSizeSmall;
    self.dSpin.displayedWhenStopped = NO;
    self.dSpin.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *acc = [NSStackView stackViewWithViews:@[self.dSpin, self.btnDoctor]];
    acc.spacing = 8; acc.alignment = NSLayoutAttributeCenterY;
    NSView *head = GMRow(GMTile(@"stethoscope", @"checkmark.seal", NSColor.systemGreenColor),
                         GMTr(@"自检"), GMTr(@"检查补丁、注入链、服务菜单和上游 API 是否都正常。"), acc);

    self.dResults = [NSStackView new];
    self.dResults.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.dResults.alignment = NSLayoutAttributeWidth;
    self.dResults.spacing = 6;
    self.dResults.edgeInsets = NSEdgeInsetsMake(12, 14, 12, 14);
    self.dResults.translatesAutoresizingMaskIntoConstraints = NO;
    [self.dResults addArrangedSubview:self.dSummary];

    // 日志
    NSScrollView *lv = [NSScrollView new];
    lv.hasVerticalScroller = YES; lv.autohidesScrollers = YES;
    lv.borderType = NSNoBorder; lv.drawsBackground = NO;
    lv.translatesAutoresizingMaskIntoConstraints = NO;
    self.dLog = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 600, 200)];
    self.dLog.editable = NO; self.dLog.selectable = YES; self.dLog.drawsBackground = NO;
    self.dLog.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.dLog.textColor = NSColor.secondaryLabelColor;
    self.dLog.textContainerInset = NSMakeSize(10, 10);
    self.dLog.verticallyResizable = YES; self.dLog.autoresizingMask = NSViewWidthSizable;
    self.dLog.textContainer.widthTracksTextView = YES;
    self.dLog.accessibilityLabel = GMTr(@"请求日志");
    lv.documentView = self.dLog;
    [lv.heightAnchor constraintEqualToConstant:220].active = YES;

    NSButton *bRefresh = GMButton(GMTr(@"刷新"), self, @selector(actRefreshLog:));
    NSButton *bFolder = GMButton(GMTr(@"在访达中显示"), self, @selector(actOpenDir:));
    NSStackView *logHead = [NSStackView stackViewWithViews:@[GMSection(GMTr(@"最近的请求")), [NSView new], bRefresh, bFolder]];
    logHead.orientation = NSUserInterfaceLayoutOrientationHorizontal; logHead.spacing = 8;
    logHead.alignment = NSLayoutAttributeCenterY;

    NSStackView *page = GMPageStack(@[
        GMHeader(GMTr(@"诊断"), NULL, GMTr(@"出问题时先来这里。系统更新后如果面板变灰，自检的第一个失败项会告诉你哪里断了。")),
        GMGroup(@[head, self.dResults]),
        logHead, GMGroup(@[lv]),
    ]);
    [page setCustomSpacing:8 afterView:logHead];
    return GMScrollPage(page);
}

- (void)refreshLog {
    NSString *log = [NSString stringWithContentsOfFile:GMLogPath() encoding:NSUTF8StringEncoding error:NULL];
    if (!log.length) { self.dLog.string = GMTr(@"还没有请求记录。"); return; }
    NSArray *lines = [log componentsSeparatedByString:@"\n"];
    NSUInteger start = lines.count > 40 ? lines.count - 40 : 0;
    self.dLog.string = [[lines subarrayWithRange:NSMakeRange(start, lines.count - start)] componentsJoinedByString:@"\n"];
    [self.dLog scrollToEndOfDocument:nil];
}
- (void)actRefreshLog:(id)s { [self refreshLog]; }

static NSString *GMStripANSI(NSString *s){
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\x1B\\[[0-9;]*m" options:0 error:NULL];
    return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
}

- (void)setDoctorRow:(NSString *)text ok:(BOOL)ok {
    NSImageView *iv = [NSImageView imageViewWithImage:GMSym(ok ? @"checkmark.circle.fill" : @"xmark.octagon.fill", nil, ok ? GMTr(@"通过") : GMTr(@"失败"))];
    iv.contentTintColor = ok ? NSColor.systemGreenColor : NSColor.systemRedColor;
    NSTextField *t = GMLabel(text, [NSFont systemFontOfSize:12], ok ? NSColor.secondaryLabelColor : NSColor.labelColor);
    NSStackView *r = [NSStackView stackViewWithViews:@[iv, t]];
    r.spacing = 6; r.alignment = NSLayoutAttributeCenterY;
    [self.dResults addArrangedSubview:r];
}

- (void)actDoctor:(id)s {
    if (self.doctorRunning) return;
    self.doctorRunning = YES;
    self.btnDoctor.enabled = NO;
    [self.dSpin startAnimation:nil];
    for (NSView *v in [self.dResults.arrangedSubviews copy]) if (v != self.dSummary) [v removeFromSuperview];
    self.dSummary.stringValue = GMTr(@"正在检查…");
    NSString *script = [GMHome() stringByAppendingPathComponent:@"doctor.sh"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *t = [NSTask new];
        t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"];
        t.arguments = @[script];
        NSPipe *pipe = [NSPipe pipe];
        t.standardOutput = pipe; t.standardError = pipe;
        NSString *out = nil;
        NSError *err = nil;
        if ([t launchAndReturnError:&err]) {
            NSData *d = [[pipe fileHandleForReading] readDataToEndOfFile];
            [t waitUntilExit];
            out = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
        }
        NSString *clean = GMStripANSI(out ?: @"");
        if (out) [clean writeToFile:[GMHome() stringByAppendingPathComponent:@"doctor-last.log"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.doctorRunning = NO;
            self.btnDoctor.enabled = YES;
            [self.dSpin stopAnimation:nil];
            if (!out) { self.dSummary.stringValue = [NSString stringWithFormat:GMTr(@"无法运行自检：%@"), err.localizedDescription ?: script]; return; }
            NSInteger okN = 0, badN = 0;
            for (NSString *raw in [clean componentsSeparatedByString:@"\n"]) {
                NSString *l = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if ([l hasPrefix:@"✓"]) { okN++; [self setDoctorRow:[[l substringFromIndex:1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ok:YES]; }
                else if ([l hasPrefix:@"✗"]) { badN++; [self setDoctorRow:[[l substringFromIndex:1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ok:NO]; }
                else if ([l hasSuffix:@" OK"]) { okN++; [self setDoctorRow:[[l substringToIndex:l.length - 3] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ok:YES]; }
                else if ([l hasSuffix:@" FAIL"]) { badN++; [self setDoctorRow:[[l substringToIndex:l.length - 5] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ok:NO]; }
            }
            if (okN + badN == 0) self.dSummary.stringValue = GMTr(@"自检没有给出结果，详见 doctor-last.log。");
            else if (badN == 0) self.dSummary.stringValue = [NSString stringWithFormat:GMTr(@"全部 %ld 项通过，一切就绪。"), (long)okN];
            else self.dSummary.stringValue = [NSString stringWithFormat:GMTr(@"%ld 项通过，%ld 项失败。先处理第一个失败项。"), (long)okN, (long)badN];
            self.dSummary.textColor = badN ? NSColor.labelColor : NSColor.secondaryLabelColor;
            [self refreshLog];
        });
    });
}

#pragma mark - 菜单验证 / 窗口

- (BOOL)validateMenuItem:(NSMenuItem *)mi { return YES; }

- (void)showPaneFromMenu:(NSMenuItem *)mi {
    NSString *ident = mi.representedObject;
    [self show:ident];
}

- (void)show:(NSString *)ident {
    if (self.compact) GMShellSetCompactInternal(NO, NSZeroRect);
    if (ident) [self select:ident];
    [self.win makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)toggleSidebar:(id)s { [self.split toggleSidebar:s]; }

@end

#pragma mark - 紧凑（隐形）模式：从其他 App 取词时，窗口缩到鼠标旁并透明，只让面板浮出

static void GMShellSetCompactInternal(BOOL on, NSRect frame){
    GMShell *s = gShell; if (!s) return;
    NSWindow *w = s.win;
    if (on) {
        if (!s.compact) { s.savedFrame = w.frame; s.compact = YES; }
        if (![s.current isEqualToString:@"write"]) [s select:@"write"];
        s.sidebarItem.collapsed = YES;
        w.toolbar.visible = NO;
        w.contentMinSize = NSMakeSize(200, 120);
        w.styleMask = NSWindowStyleMaskBorderless;
        w.opaque = NO;
        w.backgroundColor = NSColor.clearColor;
        w.alphaValue = 0.0;
        w.level = NSFloatingWindowLevel;
        if (!NSEqualRects(frame, NSZeroRect)) [w setFrame:frame display:YES];
    } else {
        if (!s.compact) { w.level = NSNormalWindowLevel; return; }
        s.compact = NO;
        w.styleMask = GMShellMask();
        w.opaque = YES;
        w.backgroundColor = NSColor.windowBackgroundColor;
        w.alphaValue = 1.0;
        w.level = NSNormalWindowLevel;
        w.toolbar.visible = YES;
        w.contentMinSize = NSMakeSize(760, 480);
        s.sidebarItem.collapsed = NO;
        if (!NSIsEmptyRect(s.savedFrame)) [w setFrame:s.savedFrame display:YES];
    }
}

#pragma mark - C 接口（供 AIHost 调用）

NSWindow *GMShellCreate(NSTextView *editor, id controller){
    if (!gShell) { gShell = [GMShell new]; [gShell buildWithEditor:editor controller:controller]; }
    return gShell.win;
}
void GMShellShow(NSString *pane){ [gShell show:pane]; }
void GMShellSelect(NSString *pane){ [gShell select:pane]; }
BOOL GMShellIsCompact(void){ return gShell.compact; }
void GMShellSetCompact(BOOL on, NSRect frame){ GMShellSetCompactInternal(on, frame); }
void GMShellSetStatus(NSString *msg){
    if (!gShell.win) return;
    gShell.win.subtitle = msg ?: @"";
}
void GMShellRunDoctor(void){ [gShell show:@"diagnostics"]; [gShell actDoctor:nil]; }
void GMShellToggleSidebar(void){ [gShell toggleSidebar:nil]; }
// 兼容旧入口
void GMManagerShow(void){ [gShell show:@"providers"]; }

// 「显示」菜单里 ⌘1…⌘5 的条目
NSArray<NSMenuItem*> *GMShellPaneMenuItems(void){
    NSMutableArray *out = [NSMutableArray array];
    int n = 1;
    for (NSInteger i = 0; i < kItemCount; i++) {
        if (kItems[i].group) continue;
        NSMenuItem *mi = [[NSMenuItem alloc] initWithTitle:GMTr(@(kItems[i].zh)) action:@selector(showPaneFromMenu:)
                                             keyEquivalent:[NSString stringWithFormat:@"%d", n++]];
        mi.target = gShell;
        mi.representedObject = @(kItems[i].ident);
        mi.image = GMSym(@(kItems[i].sym), kItems[i].fallback ? @(kItems[i].fallback) : nil, nil);
        [out addObject:mi];
    }
    return out;
}
