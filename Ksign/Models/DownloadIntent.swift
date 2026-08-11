//
//  DownloadIntent.swift
//  Ksign
//
//  المسار: Ksign/Models/DownloadIntent.swift
//

import Foundation

/// الهدف من التحميل — يختاره المستخدم من البوب عند الضغط على Get
enum DownloadIntent {
    /// تحميل الملف فقط وحفظه في المكتبة (السلوك الافتراضي)
    case downloadOnly
    /// تحميل ثم فتح شاشة التوقيع مباشرة (اسم، باندل، إلخ)
    case downloadAndSign
    /// تحميل ثم توقيع وتثبيت تلقائي بدون تدخل المستخدم
    case downloadAndInstall
}
