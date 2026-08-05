import Foundation

/// 资产记账支持的常用币种(ISO 4217 三位代码),供手动表单/详情页/设置里的
/// 选择器共用;与 ExchangeRateClient 拉取的汇率表(Frankfurter,覆盖 ECB
/// 参考汇率发布的约 30 种货币)取交集,不在这份列表里的币种不提供换算。
public enum CurrencyCatalog {
    public static let common: [(code: String, name: String)] = [
        ("CNY", "人民币"), ("USD", "美元"), ("EUR", "欧元"), ("JPY", "日元"),
        ("GBP", "英镑"), ("HKD", "港币"), ("KRW", "韩元"), ("AUD", "澳元"),
        ("CAD", "加元"), ("SGD", "新加坡元"), ("CHF", "瑞士法郎"), ("THB", "泰铢"),
    ]

    public static func name(for code: String) -> String {
        common.first { $0.code == code }?.name ?? code
    }
}
