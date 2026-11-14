#import "GMLang.h"

static NSString *gLang = nil;
static NSDictionary *gMap = nil;

static NSString *settingsPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/AppleIntel/settings.json"];
}

static void loadOnce(void) {
    if (gLang) return;
    gLang = @"zh";
    NSData *d = [NSData dataWithContentsOfFile:settingsPath()];
    if (d) {
        id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        if ([j isKindOfClass:[NSDictionary class]] && [j[@"language"] isKindOfClass:[NSString class]])
            gLang = j[@"language"];
    }
}

NSString *GMLangCode(void) { loadOnce(); return gLang; }

void GMLangSet(NSString *code) {
    loadOnce();
    if (!code.length) return;
    gLang = [code copy];
    NSMutableDictionary *j = [NSMutableDictionary dictionary];
    NSData *d = [NSData dataWithContentsOfFile:settingsPath()];
    if (d) { id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL]; if ([o isKindOfClass:[NSDictionary class]]) j = [o mutableCopy]; }
    j[@"language"] = gLang;
    NSData *out = [NSJSONSerialization dataWithJSONObject:j options:NSJSONWritingPrettyPrinted error:NULL];
    [[NSFileManager defaultManager] createDirectoryAtPath:[settingsPath() stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
    [out writeToFile:settingsPath() atomically:YES];
}

NSString *GMTr(NSString *zh) {
    loadOnce();
    if (![gLang isEqualToString:@"en"]) return zh;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gMap = @{
          @"Apple 智能（Intel）": @"Apple Intelligence (Intel)",
          @"Apple 智能（Intel 本机前端）": @"Apple Intelligence (Intel) — local front end",
          @"写作工具": @"Writing Tools",
          @"重新载入面板": @"Reload Panel",
          @"设置…": @"Settings…",
          @"前台 App": @"front app",
          @"打开写作工具": @"Open Writing Tools",
          @"用剪贴板文字改写": @"Rewrite Clipboard Text",
          @"改写前台 App 的选中文字（⌘9）": @"Rewrite Selection in Front App (⌘9)",
          @"撤销上一次改写": @"Undo Last Rewrite",
          @"显示主窗口": @"Show Main Window",
          @"结果自动复制到剪贴板": @"Copy Result to Clipboard",
          @"打开支持文件夹": @"Open Support Folder",
          @"运行自检": @"Run Self-Check",
          @"API 与状态…": @"APIs & Status…",
          @"开机自启": @"Launch at Login",
          @"授权辅助功能（全局取词）…": @"Grant Accessibility Access…",
          @"切换界面语言（中文 / English）": @"Switch Language (中文 / English)",
          @"退出": @"Quit",
          @"关于 Apple 智能（Intel）": @"About Apple Intelligence (Intel)",
          @"操作": @"Actions",
          @"用剪贴板文字打开写作工具": @"Open Writing Tools with Clipboard",
          @"已写回前台 App": @"Written back to front app",
          @"已写回前台 App（粘贴）": @"Written back (via paste)",
          @"需要在系统设置里给本 App 勾选「辅助功能」": @"Please enable Accessibility for this app in System Settings",
          @"没读到选中文字：先选中一段再按 ⌘9": @"No selection found — select some text, then press ⌘9",
          @"来自 %@，正在改写…": @"From %@ — rewriting…",
          @"正在打开面板…": @"Opening panel…",
          @"面板没弹出，正在重试…": @"Panel did not appear — retrying…",
          @"没有可撤销的改写": @"Nothing to undo",
          @"已撤销上一次改写（剩 %lu 步）": @"Undone ( %lu steps left )",
          @"自检 %ld/%ld 项通过": @"Self-check %ld/%ld passed",
          @"自检发现 %ld 项异常，见 doctor-last.log": @"Self-check found %ld issue(s) — see doctor-last.log",
          @"自检完成（输出见 doctor-last.log）": @"Self-check finished (see doctor-last.log)",
          @"语言已切换，正在重启 App…": @"Language switched — restarting…",
          @"API 与状态": @"APIs & Status",
          @"供应商": @"Providers",
          @"新增": @"Add",
          @"删除": @"Delete",
          @"设为当前": @"Set Active",
          @"保存": @"Save",
          @"测试连接": @"Test Connection",
          @"预设…": @"Presets…",
          @"打开配置目录": @"Open Config Folder",
          @"刷新": @"Refresh",
          @"名称": @"Name",
          @"请求路径": @"Request Path",
          @"备用 IP": @"Fallback IPs",
          @"关闭思维链（更快，推荐）": @"Disable reasoning (faster, recommended)",
          @"就绪": @"Ready",
          @"未配置": @"Not configured",
          @"测试中…": @"Testing…",
          @"连接正常": @"Connection OK",
          @"连接失败": @"Connection failed",
          @"已保存": @"Saved",
          @"当前供应商": @"Active provider",
          @"没有收到文本": @"No text received",
          @"服务商没有响应，请到「诊断」页运行自检": @"The provider didn't respond. Run the self-check in Diagnostics.",
          @"没有可用的服务商配置": @"No provider is configured",
          @"服务商配置不完整": @"The provider configuration is incomplete",
          @"网络失败（%.1f 秒）": @"Network error (%.1f s)",
          @"响应不是 JSON（HTTP %ld）：%@": @"Response isn't JSON (HTTP %ld): %@",
          @"服务商返回错误（HTTP %ld）：%@": @"The provider returned an error (HTTP %ld): %@",
          @"中继已启动 · %@ · %@ · socket %s": @"Relay running · %@ · %@ · socket %s",
          @"安装到「应用程序」文件夹？": @"Install in the Applications Folder?",
          @"写作工具面板不能在磁盘映像里运行。安装后 App 会自动重新打开，并推出磁盘映像。": @"Writing Tools can't run from a disk image. After installing, the app reopens automatically and ejects the disk image.",
          @"安装": @"Install",
          @"没能安装": @"Couldn't Install",
          @"请把 App 手动拖到「应用程序」文件夹，再从那里打开。": @"Drag the app to the Applications folder yourself, then open it from there.",
          @"千问 Token Plan": @"Qwen Token Plan",
          @"Ollama（本地）": @"Ollama (local)",
          @"LiteLLM（本地）": @"LiteLLM (local)",
          @"new-api / one-api（本地）": @"new-api / one-api (local)",
          @"功能": @"Features",
          @"写作": @"Writing",
          @"快捷操作": @"Shortcuts",
          @"设置": @"Settings",
          @"服务商": @"Providers",
          @"通用": @"General",
          @"诊断": @"Diagnostics",
          @"打开写作工具（⌘9 可在任意 App 中使用）": @"Open Writing Tools (⌘9 works in any app)",
          @"撤销改写": @"Undo Rewrite",
          @"正文": @"Text",
          @"选中文字后点工具栏的「写作工具」，或在任意 App 里按 ⌘9。结果由 %@ 生成，可能有误，可随时撤销。": @"Select text and click Writing Tools in the toolbar, or press ⌘9 in any app. Results come from %@, may contain mistakes, and can always be undone.",
          @"改写任意 App 里的选中文字": @"Rewrite Selected Text in Any App",
          @"在备忘录、邮件、浏览器等任意 App 中选中文字后按下，面板会在原地浮出，结果直接写回。": @"Select text in Notes, Mail, a browser or any app and press it — the panel appears in place and the result is written back.",
          @"现在打开": @"Open Now",
          @"把剪贴板里的文字放进编辑区并打开面板。": @"Puts the clipboard text in the editor and opens the panel.",
          @"撤销": @"Undo",
          @"最多可以回退 5 步。": @"Up to 5 steps.",
          @"键盘设置…": @"Keyboard Settings…",
          @"右键 → 服务": @"Right-Click → Services",
          @"直接改写、直接摘要、直接翻译、直接校对、改写并复制结果，1 秒级完成，不打开面板。可以在键盘设置里给它们设快捷键。": @"Rewrite, summarize, translate, proofread, or rewrite-and-copy in about a second without opening the panel. Assign shortcuts in Keyboard Settings.",
          @"不用切换 App 就能用写作工具。": @"Use Writing Tools without switching apps.",
          @"全局": @"Everywhere",
          @"系统服务": @"Services",
          @"例如：千问": @"e.g. Qwen",
          @"只保存在这台 Mac 上": @"Stored only on this Mac",
          @"显示密钥": @"Show Key",
          @"隐藏密钥": @"Hide Key",
          @"可留空，多个用逗号分隔": @"Optional, comma-separated",
          @"高级": @"Advanced",
          @"模型": @"Model",
          @"服务商列表": @"Providers",
          @"从预设添加": @"Add from Preset",
          @"当前使用": @"In use",
          @"当前使用中": @"In Use",
          @"任意 OpenAI 兼容服务都可以。密钥只保存在这台 Mac 上，保存后下一次请求立即生效。": @"Any OpenAI-compatible service works. Keys stay on this Mac, and changes apply to the next request.",
          @"填好后点「测试连接」确认能连上，再点「保存」。": @"Fill in the fields, click Test Connection, then Save.",
          @"还没有服务商。点 + 新增，或从预设添加。": @"No providers yet. Click + or add one from a preset.",
          @"未命名": @"Untitled",
          @"新服务商": @"New Provider",
          @"已新增。填写 Base URL、API Key 和模型后点「保存」。": @"Added. Fill in Base URL, API Key and Model, then click Save.",
          @"删除「%@」？": @"Delete “%@”?",
          @"它的 API Key 也会从这台 Mac 上移除。": @"Its API key will also be removed from this Mac.",
          @"取消": @"Cancel",
          @"已删除「%@」。": @"Deleted “%@”.",
          @"之后的请求都会发给「%@」。": @"Requests now go to “%@”.",
          @"Base URL 需要以 http:// 或 https:// 开头。": @"Base URL must start with http:// or https://.",
          @"已保存，下一次请求立即生效。": @"Saved. Applies to the next request.",
          @"正在测试…": @"Testing…",
          @"正在连接 %@ …": @"Connecting to %@…",
          @"连接正常，用时 %.2f 秒，模型回复「%@」。": @"Connected in %.2f s. The model replied “%@”.",
          @"连不上：%@。请检查 Base URL、API Key 和模型名。": @"Couldn’t connect: %@. Check Base URL, API Key and Model.",
          @"未知错误": @"unknown error",
          @"已套用「%@」预设，填入 API Key 后点「保存」。": @"Applied the “%@” preset. Enter your API key and click Save.",
          @"登录时打开": @"Open at Login",
          @"开机后自动在菜单栏待命，⌘9 随时可用。": @"Waits in the menu bar after login so ⌘9 is always ready.",
          @"改写完成后，正文同时放进剪贴板。": @"Also puts the result on the clipboard.",
          @"界面语言": @"Language",
          @"切换后 App 会自动重新打开。": @"The app reopens after switching.",
          @"授权…": @"Grant Access…",
          @"辅助功能": @"Accessibility",
          @"只用来读取你在其他 App 里选中的文字并把结果写回，不会上传。": @"Used only to read the text you select in other apps and write the result back. Nothing is uploaded.",
          @"在访达中显示": @"Show in Finder",
          @"配置与日志": @"Configuration and Logs",
          @"版本 %@ · 非官方项目，与 Apple 无关。面板来自系统自带的写作工具，生成由你配置的服务商完成。": @"Version %@ · Unofficial; not affiliated with Apple. The panel is the system’s Writing Tools; text is generated by the provider you configure.",
          @"大多数情况下保持默认即可。": @"The defaults work for most people.",
          @"权限": @"Permissions",
          @"数据": @"Data",
          @"已授权": @"Granted",
          @"未授权": @"Not granted",
          @"还没运行过自检。": @"Self-check hasn’t run yet.",
          @"自检": @"Self-Check",
          @"检查补丁、注入链、服务菜单和上游 API 是否都正常。": @"Checks patches, injection, the Services menu and the upstream API.",
          @"请求日志": @"Request Log",
          @"最近的请求": @"Recent Requests",
          @"出问题时先来这里。系统更新后如果面板变灰，自检的第一个失败项会告诉你哪里断了。": @"Start here when something breaks. If the panel turns gray after a system update, the first failed check shows where.",
          @"还没有请求记录。": @"No requests yet.",
          @"通过": @"Passed",
          @"失败": @"Failed",
          @"正在检查…": @"Checking…",
          @"无法运行自检：%@": @"Couldn’t run self-check: %@",
          @"自检没有给出结果，详见 doctor-last.log。": @"Self-check returned no results. See doctor-last.log.",
          @"全部 %ld 项通过，一切就绪。": @"All %ld checks passed. Everything is ready.",
          @"%ld 项通过，%ld 项失败。先处理第一个失败项。": @"%ld passed, %ld failed. Start with the first failure.",
          @"改写前台 App 的选中文字": @"Rewrite Selection in Front App",
          @"打开 Apple 智能（Intel）": @"Open Apple Intelligence (Intel)",
          @"服务": @"Services",
          @"隐藏 Apple 智能（Intel）": @"Hide Apple Intelligence (Intel)",
          @"隐藏其他": @"Hide Others",
          @"全部显示": @"Show All",
          @"退出 Apple 智能（Intel）": @"Quit Apple Intelligence (Intel)",
          @"编辑": @"Edit",
          @"重做": @"Redo",
          @"剪切": @"Cut",
          @"拷贝": @"Copy",
          @"粘贴": @"Paste",
          @"全选": @"Select All",
          @"显示写作工具": @"Show Writing Tools",
          @"显示": @"View",
          @"窗口": @"Window",
          @"最小化": @"Minimize",
          @"缩放": @"Zoom",
          @"关闭": @"Close",
          @"显示/隐藏侧边栏": @"Toggle Sidebar",
          @"Apple 智能的写作工具已经在你的 Intel Mac 上跑起来了。\n\n选中这段文字，点工具栏右上角的「写作工具」，Apple 原生面板就会浮出：校对、改写、友好、专业、简洁、摘要、要点、列表、表格、创作。\n\n在其他 App 里也一样：选中文字，按 ⌘9。\n\nThe quick brown fox jumps over the lazy dog. This sentence should be rewritten professionally.": @"Apple’s Writing Tools are running on your Intel Mac.\n\nSelect this text and click Writing Tools at the top right of the toolbar to open Apple’s own panel: Proofread, Rewrite, Friendly, Professional, Concise, Summary, Key Points, List, Table, Compose.\n\nIt works in other apps too: select text and press ⌘9.\n\nThe quick brown fox jumps over the lazy dog. This sentence should be rewritten professionally.",
        };
    });
    NSString *v = gMap[zh];
    return v ?: zh;
}
