import Foundation
import SwiftData

/// 记忆条目的内容类型;ppt/docx 等不解析内容的文件统一归 file。
public enum MemoryKind: String {
    case text
    case link
    case pdf
    case image
    case file

    /// 列表卡片/详情页的 SF Symbol。
    public var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .file: return "doc"
        }
    }

    public var label: String {
        switch self {
        case .text: return "文字"
        case .link: return "链接"
        case .pdf: return "PDF"
        case .image: return "图片"
        case .file: return "文件"
        }
    }
}

/// 记忆条目的整理状态:AI 整理中 / 已整理 / 整理失败(可重试,原文已保留)。
public enum MemoryStatus: String {
    case processing
    case ready
    case failed
}

/// "AI 收藏/记忆"条目:收藏的原文(提取文本 + 可选原始文件)加上 AI 整理出的
/// 标题/摘要/标签。与 TaskItem 一样放 LodoCore 统一模型定义;
/// 每个存储属性声明处给默认值、无 unique 约束(CloudKit 同步的硬性要求)。
/// 原始文件存 App Group 的 Memory/ 目录、条目只记相对路径——文件本身不进
/// CloudKit(避免吃 iCloud 配额),其他设备上条目可见可搜,原文件缺失时给占位说明。
@Model
public final class MemoryItem {
    public var uuid: UUID = UUID()
    public var kindRaw: String = "text"
    public var title: String = ""
    public var summary: String = ""
    public var tags: [String] = []
    /// 端上提取的文本(已截断),本地搜索与"问 AI"的语料。
    public var sourceText: String = ""
    /// kind == link 时的原始 URL。
    public var urlString: String?
    public var originalFileName: String?
    /// App Group 容器下的相对路径(如 "Memory/<uuid>.pdf");纯文字/链接为 nil。
    public var relativeFilePath: String?
    public var statusRaw: String = "ready"
    public var createdAt: Date = Date.now
    /// 资产条目(tags 含 assetTagName)的金额;非资产条目为 nil。资产不是独立
    /// 模型,就是打了保留标签的记忆条目,这个字段只在那种情况下有意义。
    public var assetValue: Double?
    /// 资产金额对应的 ISO 4217 币种代码(如 "CNY"/"USD")。nil 表示这条资产是
    /// 在多币种支持加入之前创建的老数据,统一按人民币对待(见 assetCurrencyOrDefault)。
    public var assetCurrency: String?
    /// 这项资产对应的负债本金(如房贷/车贷本金),与 assetValue 同币种,不单独
    /// 存币种。可以独立于 assetValue 存在(比如只记了一笔贷款还没记资产本身)。
    public var assetLiability: Double?
    /// 负债的年化利率,存百分比数值本身(如 4.5 表示 4.5%),不是小数形式。
    public var assetInterestRate: Double?

    // MARK: - 人脉字段(tags 含 contactTagName 时才有意义,与 assetValue 同思路)
    /// 昵称;姓名复用 title,备注复用 summary(和资产复用 summary 当备注同思路)。
    public var contactNickname: String?
    public var contactPhone: String?
    public var contactEmail: String?
    public var contactBirthday: Date?
    /// 喜好,自由文本。
    public var contactPreferences: String?
    /// 头像文件的 App Group 相对路径(如 "Contacts/<uuid>-avatar.jpg")。
    public var contactAvatarRelativePath: String?
    /// 多个文件附件的 App Group 相对路径;非人脉条目恒为空数组。
    public var attachmentRelativePaths: [String] = []

    // MARK: - 旅行字段(tags 含 travelTagName 时才有意义,与 assetValue 同思路)
    // 行程项不是独立模型:一张机票、一晚住宿、一个想去的地方,本身就是一条记忆
    // (订单确认单可以直接当附件存、能被记忆搜索和"问 AI"命中),这里只是把
    // "它属于哪次旅行、排在什么时候、在哪、花了多少"这几件事挂上去。
    /// 属于哪次旅行(`TravelTrip.uuid`);不建 SwiftData 关系,见 TravelTrip 的注释。
    public var travelTripUUID: UUID?
    /// 行程项类型:flight / lodging / place,见 `TravelItemKind`。
    public var travelKindRaw: String?
    /// 起讫时间。航班=起飞/降落,住宿=入住/退房,地点=计划到访的时间段(可只有开始)。
    /// 两个都为 nil 表示还没排期,按天视图会把它收进"未排期"。
    public var travelStart: Date?
    public var travelEnd: Date?
    /// 这一项的花费与币种。币种为 nil 时按 `travelCurrencyOrDefault` 兜底成人民币
    /// (和资产的 assetCurrencyOrDefault 同一个处理)。
    public var travelPrice: Double?
    public var travelCurrency: String?
    /// 主地点:住宿/地点就是它本身,航班用**到达地**。名字 + 可选坐标(搜地名选点
    /// 时一起存下来;只手输名字没选点时坐标为 nil,地图上就不画这个点)。
    public var travelPlaceName: String?
    public var travelLatitude: Double?
    public var travelLongitude: Double?
    /// 航班的出发地(其余类型为 nil),和主地点凑成地图上的一条航线。
    public var travelOriginName: String?
    public var travelOriginLatitude: Double?
    public var travelOriginLongitude: Double?
    /// 航班号/订单号/房号这类编号,自由文本。
    public var travelCode: String?
    /// 航班的补充信息(`FlightDetails` 的 JSON):航站楼、登机口、值机柜台、座位、
    /// 机型、状态……从用户导入的订单文本/截图里解析出来。字段多且全是可选的,
    /// 拆成一堆列只会让模型和备份膨胀,所以整块存。只对航班类行程项有意义。
    public var travelFlightData: Data?

    // MARK: - 菜单字段(tags 含 menuTagName 时才有意义)
    // 和资产/人脉/旅行**反过来**:这条记忆条目是**整张菜单**(照片 + OCR 原文 +
    // 整理出来的清单),一道菜不是记忆条目而是轻量的 `MenuDish`,靠
    // `MenuDish.menuUUID` 指回这条的 uuid。理由见 MenuDish 的注释。
    /// 菜单原文是什么语言(AI 给的人话,如"日语");认不出来时为 nil。
    public var menuSourceLanguage: String?
    /// 翻译成了哪种语言(整理那一刻的应用内语言,如"中文")。之后用户改了
    /// 应用内语言,已经存下的译名不会跟着变,这个字段说明的就是"这份译名是哪种语言"。
    public var menuTargetLanguage: String?
    /// 整张菜单的币种(ISO 4217);菜单上只有符号、AI 也认不出来时为 nil,
    /// 价格就只显示数字。一张菜单一个币种,不逐道菜存。
    public var menuCurrency: String?

    public init(
        kind: MemoryKind,
        title: String = "",
        summary: String = "",
        tags: [String] = [],
        sourceText: String = "",
        urlString: String? = nil,
        originalFileName: String? = nil,
        relativeFilePath: String? = nil,
        status: MemoryStatus = .processing,
        assetValue: Double? = nil,
        assetCurrency: String? = nil,
        assetLiability: Double? = nil,
        assetInterestRate: Double? = nil,
        contactNickname: String? = nil,
        contactPhone: String? = nil,
        contactEmail: String? = nil,
        contactBirthday: Date? = nil,
        contactPreferences: String? = nil,
        contactAvatarRelativePath: String? = nil,
        attachmentRelativePaths: [String] = [],
        travelTripUUID: UUID? = nil,
        travelKind: TravelItemKind? = nil,
        travelStart: Date? = nil,
        travelEnd: Date? = nil,
        travelPrice: Double? = nil,
        travelCurrency: String? = nil,
        travelPlaceName: String? = nil,
        travelLatitude: Double? = nil,
        travelLongitude: Double? = nil,
        travelOriginName: String? = nil,
        travelOriginLatitude: Double? = nil,
        travelOriginLongitude: Double? = nil,
        travelCode: String? = nil,
        travelFlightData: Data? = nil,
        menuSourceLanguage: String? = nil,
        menuTargetLanguage: String? = nil,
        menuCurrency: String? = nil
    ) {
        self.uuid = UUID()
        self.kindRaw = kind.rawValue
        self.title = title
        self.summary = summary
        self.tags = tags
        self.sourceText = sourceText
        self.urlString = urlString
        self.originalFileName = originalFileName
        self.relativeFilePath = relativeFilePath
        self.statusRaw = status.rawValue
        self.createdAt = Date()
        self.assetValue = assetValue
        self.assetCurrency = assetCurrency
        self.assetLiability = assetLiability
        self.assetInterestRate = assetInterestRate
        self.contactNickname = contactNickname
        self.contactPhone = contactPhone
        self.contactEmail = contactEmail
        self.contactBirthday = contactBirthday
        self.contactPreferences = contactPreferences
        self.contactAvatarRelativePath = contactAvatarRelativePath
        self.attachmentRelativePaths = attachmentRelativePaths
        self.travelTripUUID = travelTripUUID
        self.travelKindRaw = travelKind?.rawValue
        self.travelStart = travelStart
        self.travelEnd = travelEnd
        self.travelPrice = travelPrice
        self.travelCurrency = travelCurrency
        self.travelPlaceName = travelPlaceName
        self.travelLatitude = travelLatitude
        self.travelLongitude = travelLongitude
        self.travelOriginName = travelOriginName
        self.travelOriginLatitude = travelOriginLatitude
        self.travelOriginLongitude = travelOriginLongitude
        self.travelCode = travelCode
        self.travelFlightData = travelFlightData
        self.menuSourceLanguage = menuSourceLanguage
        self.menuTargetLanguage = menuTargetLanguage
        self.menuCurrency = menuCurrency
    }

    public var kind: MemoryKind { MemoryKind(rawValue: kindRaw) ?? .text }
    public var status: MemoryStatus { MemoryStatus(rawValue: statusRaw) ?? .ready }
    /// 保留标签:打了这个标签的记忆条目按"资产"对待(默认从记忆列表隐藏,
    /// 筛选里显式选中才显示,并在列表顶部汇总)。
    public static let assetTagName = "资产"
    public var isAsset: Bool { tags.contains(Self.assetTagName) }
    /// 老数据(多币种支持加入前创建)没有 assetCurrency,统一按人民币对待——
    /// 展示格式化、汇总换算都读这个,不直接读 assetCurrency。
    public var assetCurrencyOrDefault: String { assetCurrency ?? "CNY" }
    /// 保留标签:打了这个标签的记忆条目按"人脉"对待,和资产同一套隐藏/筛选规则。
    public static let contactTagName = "人脉"
    public var isContact: Bool { tags.contains(Self.contactTagName) }
    /// 保留标签:AI 在对话中主动捕捉到的重点事实/事件(不是用户明确要求收藏,
    /// 也不像 suggestMemorize 那样需要用户点按钮确认),打这个标签和用户
    /// 主动收藏/确认过的记忆区分开;不参与资产/人脉那套隐藏筛选,正常显示。
    public static let autoTagName = "AI记录"
    public var isAutoRecorded: Bool { tags.contains(Self.autoTagName) }
    /// 保留标签:用户自己收藏的健康资料(体检报告、用药、饮食记录等),
    /// 健康页会把它们列出来并拼进 analyzeHealth 的上下文。和"AI记录"一样
    /// 只是保留、不隐藏——健康记录该在记忆列表里正常出现。
    public static let healthTagName = "健康"
    public var isHealth: Bool { tags.contains(Self.healthTagName) }
    /// 保留标签:一次旅行里的行程项(航班/住宿/地点)。和"健康"/"AI记录"同组——
    /// 是保留标签(不能改名/删除)但**不**默认隐藏,在记忆列表里正常显示、正常搜。
    public static let travelTagName = "旅行"
    public var isTravel: Bool { tags.contains(Self.travelTagName) }
    public var travelKind: TravelItemKind? {
        travelKindRaw.flatMap(TravelItemKind.init(rawValue:))
    }
    /// 老数据/没填币种时统一按人民币对待(同 assetCurrencyOrDefault)。
    public var travelCurrencyOrDefault: String { travelCurrency ?? "CNY" }
    /// 保留标签:一张整理过的菜单(拍照/截图/文本导入,AI 拆成菜品清单)。
    /// 和「健康」「旅行」同组——是保留标签(不能改名/删除)但**不**默认隐藏,
    /// 在记忆列表里正常显示、正常搜(菜单照片本来就是值得留着的资料)。
    public static let menuTagName = "菜单"
    public var isMenu: Bool { tags.contains(Self.menuTagName) }

    /// 全部保留标签的集合,供 UI 层统一过滤(标签管理页的可管理列表、详情页
    /// 标签编辑器的候选与手输校验都应该引用这一份定义,不要各自维护一份
    /// 排除规则——历史上就是因为三处各写各的,漏了"人脉"没被
    /// MemoryTagManageView 保护)。这份集合只管"能不能被当成普通标签改名/
    /// 删除/手动增删",和下面 `hiddenByDefaultTagNames`(默认隐藏筛选)是
    /// 两个不同维度——"AI记录"是保留标签但不隐藏,不能共用同一份集合。
    public static let reservedTagNames: Set<String> = [
        assetTagName, contactTagName, autoTagName, healthTagName, travelTagName,
        menuTagName,
    ]
    /// 默认从记忆列表/附件选择器隐藏、需要显式打开对应开关才显示的标签
    /// (资产、人脉都是隐私/结构化数据,不该跟日常收藏混在一起刷屏)。
    /// "AI记录"/"健康"/"旅行"/"菜单"不在这份集合里——它们是保留标签,但仍应正常显示、
    /// 可被当成普通标签筛选,只是不能被改名/删除。
    public static let hiddenByDefaultTagNames: Set<String> = [assetTagName, contactTagName]

    /// 本地即时过滤的匹配:标题/摘要/标签/原文任一命中即可。
    public func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if title.localizedStandardContains(query) { return true }
        if summary.localizedStandardContains(query) { return true }
        if tags.contains(where: { $0.localizedStandardContains(query) }) { return true }
        return sourceText.localizedStandardContains(query)
    }
}
