// CompositorZHDylib — 运行时 AppKit / SwiftUI 文本汉化（B5：+CoreText 行排版层拦截）
//
// 三层机制：
//  A. zh-Hans.lproj/Localizable.strings —— SwiftUI Text("字面量") 自动本地化（系统机制）。
//  B. libCompositorZH.dylib AppKit 层 —— 滤镜名/混合模式等 enum rawValue 动态串，
//     最终经 NSMenuItem/NSButton/NSTextField 的 setTitle:/setStringValue: 流出，
//     swizzle 这些入口，查 AppKitOverrides.plist 翻译（B 层，字典门控）。
//  C. libCompositorZH.dylib CoreText 层（B5 新增）—— SwiftUI Text(变量)（如
//     dimension("Width") 把字面量传入 String 参数再 Text(title)）是 verbatim 渲染：
//     不查 .strings、不走任何 NSTextField/NSAttributedString 出口。实测其可见文本
//     唯一汇聚点是 CoreText 的 CTLineCreateWithAttributedString。本层用静态
//     __DATA,__interpose 拦截它，用 LC_SYMTAB 直查符号表拿到未污染的原始函数地址
//     （dlsym 会被 interpose 污染；export trie 在共享缓存 chained fixups 下不存在），
//     字典命中则重建 attributed string 再排版。只改渲染层，不动逻辑值（枚举回读、
//     状态判断仍是英文原值），零副作用。
//
// 安全模型（全局一致）：只在「传入值恰好等于某个字典键」时才翻译（字典门控），
// 不会动用户输入、不会动非 UI 字符串。局限：画布上用户输入的文本若恰好等于某个
// 词条（如混合模式名 "Multiply"），显示层也会被翻译（数据不受影响）。
//
// 编译：clang -dynamiclib -fobjc-arc -framework AppKit -framework Foundation
//       -framework CoreText

#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSDictionary<NSString *, NSString *> *zh_dict = nil;
static NSDictionary<NSString *, NSString *> *zh_dict_lower = nil; // 小写索引
static NSSet<NSString *> *zh_readback_titles = nil; // 会被回读解析的标题（混合模式）
static BOOL zh_debug = NO;

static void (*zh_orig_miSetTitle)(id, SEL, NSString *);
static id (*zh_orig_miInit)(id, SEL, NSString *, SEL, NSString *);
static void (*zh_orig_bSetTitle)(id, SEL, NSString *);
static void (*zh_orig_segSetLabel)(id, SEL, NSString *, NSInteger);
static void (*zh_orig_tiSetLabel)(id, SEL, NSString *);
static void (*zh_orig_menuSetTitle)(id, SEL, NSString *);
static void (*zh_orig_tfSetString)(id, SEL, NSString *);
static void (*zh_orig_tfSetAttributed)(id, SEL, NSAttributedString *);
static void (*zh_orig_tvSetString)(id, SEL, NSString *);
static void (*zh_orig_tvSetAttributed)(id, SEL, NSAttributedString *);
static void (*zh_orig_winSetTitle)(id, SEL, NSString *);

static void *zh_orig_key = &zh_orig_key; // 已处理的英文原文（幂等标记）

static void zh_log(NSString *fmt, ...) __attribute__((format(NSString, 1, 2)));
static void zh_log(NSString *fmt, ...) {
    if (!zh_debug) return;
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    FILE *f = fopen("/tmp/compositor_zh_dylib.log", "a");
    if (f) { fprintf(f, "[CompositorZH] %s\n", msg.UTF8String); fclose(f); }
}

static NSDictionary *zh_load_dict(void) {
    NSBundle *main = [NSBundle mainBundle];
    if (!main) return @{};
    for (NSString *lproj in @[@"zh-Hans", @"zh_CN"]) {
        NSString *p = [NSString stringWithFormat:@"%@/Contents/Resources/%@.lproj/AppKitOverrides.plist",
                       main.bundlePath, lproj];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d.count) {
            zh_log(@"dict: %@ (%lu entries)", p, (unsigned long)d.count);
            return d;
        }
    }
    zh_log(@"WARN: AppKitOverrides.plist not found");
    return @{};
}

static NSString *zh_translate_label(NSString *s); // 前向声明（模式规则内部复用）

// 翻译：精确 -> 小写 -> 去尾 "…" -> "Last Filter: " 前缀 -> 插值整句模式
static NSString *zh_translate(NSString *title) {
    if (title.length == 0) return nil;
    if (title.length > 256) return nil; // 护栏：UI 词条（含状态栏长提示）不会超过 256 字符，跳过超长文本（如正文）
    NSString *hit = zh_dict[title];
    if (hit) return hit;
    hit = zh_dict_lower[title.lowercaseString];
    if (hit) return hit;
    if ([title hasSuffix:@"…"]) {
        NSString *bare = [title substringToIndex:title.length - 1];
        NSString *hb = zh_dict[bare];
        if (!hb) hb = zh_dict_lower[bare.lowercaseString];
        if (hb) return [hb stringByAppendingString:@"…"];
    }
    if ([title hasPrefix:@"Last Filter: "]) {
        NSString *rest = [title substringFromIndex:@"Last Filter: ".length];
        NSString *tr = zh_translate(rest);
        if (tr) return [NSString stringWithFormat:@"上次滤镜：%@", tr];
    }
    // ---- 运行时插值整句（对话框标题）：前缀/后缀模式匹配 ----
    // 这类串在源码里是 "Save changes to \(文件名)?"，运行时才拼成名，无法进词典，用模式规则。
    {
        NSString *pre = @"Save changes to ", *suf = @"?";
        if ([title hasPrefix:pre] && [title hasSuffix:suf] && title.length > pre.length + suf.length) {
            NSString *mid = [title substringWithRange:NSMakeRange(pre.length, title.length - pre.length - suf.length)];
            return [NSString stringWithFormat:@"要保存对 %@ 的更改吗？", zh_translate_label(mid) ?: mid];
        }
    }
    {
        NSString *pre = @"A new version of ", *suf = @" is available!";
        if ([title hasPrefix:pre] && [title hasSuffix:suf] && title.length > pre.length + suf.length) {
            NSString *mid = [title substringWithRange:NSMakeRange(pre.length, title.length - pre.length - suf.length)];
            return [NSString stringWithFormat:@"%@ 有新版本可用！", mid];
        }
    }
    {
        NSString *pre = @"“", *suf = @"” was changed on disk.";
        if ([title hasPrefix:pre] && [title hasSuffix:suf] && title.length > pre.length + suf.length) {
            NSString *mid = [title substringWithRange:NSMakeRange(pre.length, title.length - pre.length - suf.length)];
            return [NSString stringWithFormat:@"“%@”已在磁盘上被更改。", zh_translate_label(mid) ?: mid];
        }
    }
    return nil;
}

// 显示层标签翻译（C 层用）：zh_translate + "Untitled N" 序号变体
static NSString *zh_translate_label(NSString *s) {
    NSString *tr = zh_translate(s);
    if (tr) return tr;
    if ([s isEqualToString:@"Untitled"]) return @"未命名";
    if ([s hasPrefix:@"Untitled "]) return [@"未命名" stringByAppendingString:[s substringFromIndex:8]];
    return nil;
}

static BOOL zh_is_blend_readback(NSString *title) {
    return title && [zh_readback_titles containsObject:title];
}

static void zh_apply_mi(id item, NSString *title) {
    NSString *tr = zh_translate(title);
    if (!tr) {
        if (objc_getAssociatedObject(item, zh_orig_key)) objc_removeAssociatedObjects(item);
        zh_orig_miSetTitle(item, @selector(setTitle:), title);
        return;
    }
    objc_setAssociatedObject(item, zh_orig_key, title, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (zh_is_blend_readback(title)) {
        // 回读安全路径：title 保持英文，attributedTitle 显示中文
        NSMutableDictionary *a = [@{
            NSFontAttributeName: [NSFont menuFontOfSize:13],
            NSForegroundColorAttributeName: [NSColor labelColor]
        } mutableCopy];
        zh_orig_miSetTitle(item, @selector(setTitle:), title);
        [(NSMenuItem *)item setAttributedTitle:
            [[NSAttributedString alloc] initWithString:tr attributes:a]];
        zh_log(@"menuItem(attr) \"%@\" -> \"%@\"", title, tr);
    } else {
        zh_orig_miSetTitle(item, @selector(setTitle:), tr);
        zh_log(@"menuItem \"%@\" -> \"%@\"", title, tr);
    }
}

static void zh_miSetTitle(id self, SEL _cmd, NSString *title) {
    if (![title isKindOfClass:[NSString class]] || title.length == 0) {
        zh_orig_miSetTitle(self, _cmd, title);
        return;
    }
    NSString *stored = objc_getAssociatedObject(self, zh_orig_key);
    if ([stored isEqualToString:title]) return; // 幂等
    zh_apply_mi(self, title);
}

static id zh_miInit(id self, SEL _cmd, NSString *title, SEL action, NSString *key) {
    id obj = zh_orig_miInit(self, _cmd, title, action, key);
    if (obj && [title isKindOfClass:[NSString class]] && title.length > 0) {
        zh_apply_mi(obj, title);
    }
    return obj;
}

static void zh_bSetTitle(id self, SEL _cmd, NSString *title) {
    if (![title isKindOfClass:[NSString class]] || title.length == 0) {
        zh_orig_bSetTitle(self, _cmd, title);
        return;
    }
    NSString *stored = objc_getAssociatedObject(self, zh_orig_key);
    if ([stored isEqualToString:title]) return;
    NSString *tr = zh_translate(title);
    if (tr) {
        objc_setAssociatedObject(self, zh_orig_key, title, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        zh_log(@"button \"%@\" -> \"%@\"", title, tr);
        zh_orig_bSetTitle(self, _cmd, tr);
    } else {
        if (stored) objc_removeAssociatedObjects(self);
        zh_orig_bSetTitle(self, _cmd, title);
    }
}

// ---- 扩展：NSSegmentedControl.setLabel:forSegment: ----
static void zh_segSetLabel(id self, SEL _cmd, NSString *label, NSInteger seg) {
    if ([label isKindOfClass:[NSString class]] && label.length) {
        NSString *tr = zh_translate(label);
        if (tr) label = tr;
    }
    zh_orig_segSetLabel(self, _cmd, label, seg);
}

// ---- 扩展：NSToolbarItem.setLabel: / setPaletteLabel: ----
static void zh_tiSetLabel(id self, SEL _cmd, NSString *label) {
    if ([label isKindOfClass:[NSString class]] && label.length) {
        NSString *tr = zh_translate(label);
        if (tr) label = tr;
    }
    zh_orig_tiSetLabel(self, _cmd, label);
}

// ---- 扩展：NSMenu.setTitle:（子菜单标题）----
static void zh_menuSetTitle(id self, SEL _cmd, NSString *title) {
    if ([title isKindOfClass:[NSString class]] && title.length) {
        NSString *tr = zh_translate(title);
        if (tr) title = tr;
    }
    zh_orig_menuSetTitle(self, _cmd, title);
}

// ---- 扩展：NSTextField.setText/setStringValue:（AppKit 承载的动态标签）----
// 字典门控：仅当传入值恰好等于某个字典键才翻译，安全不动其它文本。
static void zh_tfSetString(id self, SEL _cmd, NSString *value) {
    if ([value isKindOfClass:[NSString class]] && value.length) {
        NSString *stored = objc_getAssociatedObject(self, zh_orig_key);
        if ([stored isEqualToString:value]) { // 已是翻译态，跳过重复
            return;
        }
        NSString *tr = zh_translate(value);
        if (tr) {
            objc_setAssociatedObject(self, zh_orig_key, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            zh_log(@"textField \"%@\" -> \"%@\"", value, tr);
            zh_orig_tfSetString(self, _cmd, tr);
            return;
        }
        if (stored) objc_removeAssociatedObjects(self); // 变成非键文本，清除标记
    }
    zh_orig_tfSetString(self, _cmd, value);
}

// 富文本标签：翻译其中的字符串内容，保留属性。
static void zh_tfSetAttributed(id self, SEL _cmd, NSAttributedString *value) {
    if ([value isKindOfClass:[NSAttributedString class]] && value.length) {
        NSString *plain = value.string;
        NSString *tr = zh_translate(plain);
        if (tr) {
            objc_setAssociatedObject(self, zh_orig_key, plain, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            zh_log(@"textField(attr) \"%@\" -> \"%@\"", plain, tr);
            NSMutableAttributedString *m = [value mutableCopy];
            [m replaceCharactersInRange:NSMakeRange(0, m.length) withString:tr];
            zh_orig_tfSetAttributed(self, _cmd, m);
            return;
        }
    }
    zh_orig_tfSetAttributed(self, _cmd, value);
}

// ---- 扩展：NSTextView.setString: / setAttributedString: ----
static void zh_tvSetString(id self, SEL _cmd, NSString *value) {
    if ([value isKindOfClass:[NSString class]] && value.length) {
        NSString *stored = objc_getAssociatedObject(self, zh_orig_key);
        if ([stored isEqualToString:value]) return;
        NSString *tr = zh_translate(value);
        if (tr) {
            objc_setAssociatedObject(self, zh_orig_key, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            zh_log(@"textView \"%@\" -> \"%@\"", value, tr);
            zh_orig_tvSetString(self, _cmd, tr);
            return;
        }
        if (stored) objc_removeAssociatedObjects(self);
    }
    zh_orig_tvSetString(self, _cmd, value);
}

static void zh_tvSetAttributed(id self, SEL _cmd, NSAttributedString *value) {
    if ([value isKindOfClass:[NSAttributedString class]] && value.length) {
        NSString *plain = value.string;
        NSString *tr = zh_translate(plain);
        if (tr) {
            objc_setAssociatedObject(self, zh_orig_key, plain, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            zh_log(@"textView(attr) \"%@\" -> \"%@\"", plain, tr);
            NSMutableAttributedString *m = [value mutableCopy];
            [m replaceCharactersInRange:NSMakeRange(0, m.length) withString:tr];
            zh_orig_tvSetAttributed(self, _cmd, m);
            return;
        }
    }
    zh_orig_tvSetAttributed(self, _cmd, value);
}

// ---- B4 扩展：NSWindow.setTitle:（窗口/标签标题 "Untitled" 等）----
static void zh_winSetTitle(id self, SEL _cmd, NSString *title) {
    if ([title isKindOfClass:[NSString class]] && title.length) {
        NSString *tr = zh_translate_label(title);
        if (tr) {
            zh_log(@"windowTitle \"%@\" -> \"%@\"", title, tr);
            zh_orig_winSetTitle(self, _cmd, tr);
            return;
        }
    }
    zh_orig_winSetTitle(self, _cmd, title);
}

// =============================================================================
// C 层（B5）：CoreText 行排版拦截 —— SwiftUI Text(变量) 的真实可见出口
// =============================================================================
#define ZH_DYLD_INTERPOSE(_replacement,_original) \
  __attribute__((used)) static struct{ const void* replacement; const void* replacee; } \
  zh_interpose_##_original __attribute__ ((section ("__DATA,__interpose"))) = \
  { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_original };

typedef CFAttributedStringRef (*zh_CFAttrFn)(CFAllocatorRef, CFStringRef, CFDictionaryRef);
typedef CTLineRef (*zh_LineCreateFn)(CFAttributedStringRef);

static volatile zh_CFAttrFn    zh_real_CFAttr = NULL;
static volatile zh_LineCreateFn zh_real_LineC = NULL;

static void *zh_resolve_real(const char *img_sub, const char *symbol) {
    uint32_t n = _dyld_image_count();
    char wanted[128];
    snprintf(wanted, sizeof(wanted), "_%s", symbol);
    for (uint32_t i = 0; i < n; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path || !strstr(path, img_sub)) continue;
        const struct mach_header *hdr = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const uint8_t *cur = (const uint8_t *)hdr + sizeof(struct mach_header_64);
        const struct segment_command_64 *linkedit = NULL;
        const struct symtab_command *sym = NULL;
        for (uint32_t c = 0; c < hdr->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)cur;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *sg = (const struct segment_command_64 *)cur;
                if (!strcmp(sg->segname, SEG_LINKEDIT)) linkedit = sg;
            } else if (lc->cmd == LC_SYMTAB) {
                sym = (const struct symtab_command *)cur;
            }
            cur += lc->cmdsize;
        }
        if (!linkedit || !sym || !sym->nsyms) continue;
        uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
        const struct nlist_64 *syms = (const struct nlist_64 *)(base + sym->symoff);
        const char *strs = (const char *)(base + sym->stroff);
        for (uint32_t k = 0; k < sym->nsyms; k++) {
            const struct nlist_64 *e = &syms[k];
            if (e->n_un.n_strx == 0 || !(e->n_type & N_SECT)) continue;
            if (!strcmp(strs + e->n_un.n_strx, wanted))
                return (void *)(slide + e->n_value);
        }
        zh_log(@"RES %@: not found in %s", @(symbol), img_sub);
    }
    return NULL;
}

static void zh_ct_resolve(void) {
    if (!zh_real_CFAttr)
        zh_real_CFAttr = (zh_CFAttrFn)zh_resolve_real("CoreFoundation.framework", "CFAttributedStringCreate");
    if (!zh_real_LineC)
        zh_real_LineC = (zh_LineCreateFn)zh_resolve_real("CoreText.framework", "CTLineCreateWithAttributedString");
    zh_log(@"ct resolve: CFAttr=%p LineC=%p", (void *)zh_real_CFAttr, (void *)zh_real_LineC);
}

// 线程本地重入护栏（绘制可能发生在任意线程）
static _Thread_local int zh_tls_depth = 0;

// 替换函数：字典命中 → 用原文属性重建翻译后的 attributed string 再排版
static CTLineRef zh_ct_LineCreate(CFAttributedStringRef as) {
    zh_LineCreateFn real = zh_real_LineC;
    if (!real) return NULL;
    if (zh_tls_depth || !as) return real(as);
    zh_tls_depth = 1;
    CTLineRef out = NULL;
    CFStringRef s = CFAttributedStringGetString(as);
    if (s && CFGetTypeID((CFTypeRef)s) == CFStringGetTypeID()) {
        NSString *ns = (__bridge NSString *)s;
        NSString *tr = zh_translate_label(ns);
        if (tr && zh_real_CFAttr) {
            CFDictionaryRef attrs = CFAttributedStringGetAttributes(as, 0, NULL);
            CFAttributedStringRef nas = zh_real_CFAttr(NULL, (__bridge CFStringRef)tr, attrs);
            if (nas) {
                out = real(nas);
                CFRelease(nas);
            }
            zh_log(@"ctLine \"%@\" -> \"%@\"", ns, tr);
        }
    }
    if (!out) out = real(as);
    zh_tls_depth = 0;
    return out;
}
ZH_DYLD_INTERPOSE(zh_ct_LineCreate, CTLineCreateWithAttributedString)

__attribute__((constructor))
static void zh_init(void) {
    @autoreleasepool {
        zh_debug = !!getenv("COMPOSITOR_ZH_DEBUG");
        zh_dict = zh_load_dict();
        // C 层地址解析（词典缺失也不影响透传）
        zh_ct_resolve();
        if (!zh_dict.count) return;
        // 小写索引
        NSMutableDictionary *low = [NSMutableDictionary dictionaryWithCapacity:zh_dict.count];
        for (NSString *k in zh_dict) {
            NSString *lk = k.lowercaseString;
            if (!low[lk]) low[lk] = zh_dict[k];
        }
        zh_dict_lower = [low copy];
        // LayerBlendMode.groups 的 23 个混合模式（会回读 title 解析枚举）
        zh_readback_titles = [NSSet setWithArray:@[
            @"Normal", @"Darken", @"Multiply", @"Color Burn", @"Linear Burn",
            @"Lighten", @"Screen", @"Color Dodge", @"Linear Dodge (Add)",
            @"Overlay", @"Soft Light", @"Hard Light", @"Vivid Light",
            @"Linear Light", @"Pin Light", @"Hard Mix", @"Difference",
            @"Exclusion", @"Subtract", @"Divide", @"Hue", @"Saturation",
            @"Color", @"Luminosity",
        ]];

        Method m;
        Class miClass = [NSMenuItem class];
        if ((m = class_getInstanceMethod(miClass, @selector(setTitle:)))) {
            zh_orig_miSetTitle = (void (*)(id, SEL, NSString *))method_getImplementation(m);
            method_setImplementation(m, (IMP)zh_miSetTitle);
        }
        if ((m = class_getInstanceMethod(miClass, @selector(initWithTitle:action:keyEquivalent:)))) {
            zh_orig_miInit = (id (*)(id, SEL, NSString *, SEL, NSString *))method_getImplementation(m);
            method_setImplementation(m, (IMP)zh_miInit);
        }
        if ((m = class_getInstanceMethod([NSButton class], @selector(setTitle:)))) {
            zh_orig_bSetTitle = (void (*)(id, SEL, NSString *))method_getImplementation(m);
            method_setImplementation(m, (IMP)zh_bSetTitle);
        }
        if ((m = class_getInstanceMethod([NSSegmentedControl class], @selector(setLabel:forSegment:)))) {
            zh_orig_segSetLabel = (void (*)(id, SEL, NSString *, NSInteger))method_getImplementation(m);
            method_setImplementation(m, (IMP)zh_segSetLabel);
        }
        if ((m = class_getInstanceMethod([NSToolbarItem class], @selector(setLabel:)))) {
            zh_orig_tiSetLabel = (void (*)(id, SEL, NSString *))method_getImplementation(m);
            method_setImplementation(m, (IMP)zh_tiSetLabel);
        }
        if ((m = class_getInstanceMethod([NSToolbarItem class], @selector(setPaletteLabel:)))) {
            // 复用同一 handler（签名一致）
            method_setImplementation(m, (IMP)zh_tiSetLabel);
        }
        if ((m = class_getInstanceMethod([NSMenu class], @selector(setTitle:)))) {
            zh_orig_menuSetTitle = (void (*)(id, SEL, NSString *))method_getImplementation(m);
            method_setImplementation(m, (IMP)zh_menuSetTitle);
        }
        if ((m = class_getInstanceMethod([NSTextField class], @selector(setStringValue:)))) {
            zh_orig_tfSetString = (void (*)(id, SEL, NSString *))method_getImplementation(m);
            method_setImplementation(m, (IMP)zh_tfSetString);
        }
        if ((m = class_getInstanceMethod([NSTextField class], @selector(setAttributedStringValue:)))) {
            zh_orig_tfSetAttributed = (void (*)(id, SEL, NSAttributedString *))method_getImplementation(m);
            method_setImplementation(m, (IMP)zh_tfSetAttributed);
        }
        if ((m = class_getInstanceMethod([NSTextView class], @selector(setString:)))) {
            zh_orig_tvSetString = (void (*)(id, SEL, NSString *))method_getImplementation(m);
            method_setImplementation(m, (IMP)zh_tvSetString);
        }
        if ((m = class_getInstanceMethod([NSTextView class], @selector(setAttributedString:)))) {
            zh_orig_tvSetAttributed = (void (*)(id, SEL, NSAttributedString *))method_getImplementation(m);
            method_setImplementation(m, (IMP)zh_tvSetAttributed);
        }
        if ((m = class_getInstanceMethod([NSWindow class], @selector(setTitle:)))) {
            zh_orig_winSetTitle = (void (*)(id, SEL, NSString *))method_getImplementation(m);
            method_setImplementation(m, (IMP)zh_winSetTitle);
        }
        zh_log(@"swizzles installed (B5: B-layer + CoreText interpose), dict=%lu lower=%lu",
               (unsigned long)zh_dict.count, (unsigned long)zh_dict_lower.count);
    }
}
