import Foundation

/// 地点的细分类别,只用来在列表和地图上换图标(纯逻辑,`TravelPlaceCategoryTests`)。
///
/// 行程项的类型(`TravelItemKind`)只分到"地点"为止,可一天里的景点、餐馆、博物馆、
/// 商场在地图上都是同一个大头针,分不清哪个是去吃饭的。这里**按名字里的关键词**猜
/// (标题 + 地点名,中日英三种写法都认),猜不出来就是普通地点——不另存字段、不问 AI,
/// 名字改了图标自然跟着变。住宿一律是酒店,交通类照旧用各自的图标。
public enum TravelPlaceCategory: String, CaseIterable, Sendable {
    case restaurant, cafe, bar, museum, shopping, park, temple, sight, station, airport, hotel, other

    public var systemImage: String {
        switch self {
        case .restaurant: return "fork.knife"
        case .cafe: return "cup.and.saucer"
        case .bar: return "wineglass"
        case .museum: return "building.columns"
        case .shopping: return "bag"
        case .park: return "tree"
        case .temple: return "house.lodge"
        case .sight: return "camera"
        case .station: return "tram.fill.tunnel"
        case .airport: return "airplane.arrival"
        case .hotel: return "bed.double"
        case .other: return "mappin.and.ellipse"
        }
    }

    /// 关键词,按先后顺序匹配(先具体后宽泛:「美术馆」先于「馆」,「咖啡」先于「店」)。
    /// 全部小写比较。
    private static let keywords: [(TravelPlaceCategory, [String])] = [
        (.airport, ["机场", "空港", "airport"]),
        (.station, ["车站", "火车站", "地铁站", "駅", "站", "码头", "港口", "station", "terminal", "巴士总站"]),
        (.museum, ["博物馆", "博物館", "美术馆", "美術館", "纪念馆", "記念館", "科学馆", "科技馆", "水族馆", "水族館",
                   "museum", "gallery", "aquarium"]),
        (.cafe, ["咖啡", "カフェ", "喫茶", "茶室", "甜品", "cafe", "café", "coffee", "bakery", "面包"]),
        (.bar, ["酒吧", "居酒屋", "バー", "bar", "pub", "izakaya"]),
        (.restaurant, ["餐厅", "餐館", "餐馆", "饭店", "食堂", "料理", "拉面", "ラーメン", "寿司", "烤肉", "焼肉",
                       "火锅", "烧鸟", "焼鳥", "天妇罗", "天ぷら", "定食", "牛丼", "乌冬", "うどん", "荞麦", "そば",
                       "小吃", "美食", "市场美食", "食べ", "restaurant", "ramen", "sushi", "bistro", "diner", "grill",
                       "kitchen", "餐", "吃"]),
        (.shopping, ["商场", "商城", "百货", "百貨", "购物", "奥特莱斯", "outlet", "mall", "市场", "市場", "商店街",
                     "药妆", "ドン・キホーテ", "唐吉诃德", "shopping", "market", "store", "店"]),
        (.temple, ["寺", "神社", "神宫", "神宮", "大社", "教堂", "清真寺", "cathedral", "church", "temple", "shrine"]),
        (.park, ["公园", "公園", "庭园", "庭園", "植物园", "動物園", "动物园", "花园", "湖", "山", "海滩", "海岸",
                 "park", "garden", "zoo", "beach", "lake"]),
        (.sight, ["塔", "城", "宫", "宮", "桥", "橋", "广场", "展望台", "观景", "瀑布", "遗址", "古迹", "老街",
                  "tower", "castle", "palace", "bridge", "square", "viewpoint", "falls"]),
    ]

    /// 猜一个地点属于哪类。`title` 和 `placeName` 都参与,先看标题(用户起的名字
    /// 通常更能说明去干什么:「一兰拉面」的地点名可能只写了「新宿」)。
    public static func classify(title: String, placeName: String? = nil) -> TravelPlaceCategory {
        for text in [title, placeName ?? ""] {
            let lowered = text.lowercased()
            guard !lowered.isEmpty else { continue }
            for (category, words) in keywords where words.contains(where: { lowered.contains($0) }) {
                return category
            }
        }
        return .other
    }
}

extension TravelEntry {
    /// 列表和地图上用的图标:地点按细分类别换图标,住宿、交通用各自类型的图标。
    public var symbolName: String {
        switch kind {
        case .place: return TravelPlaceCategory.classify(title: title, placeName: placeName).systemImage
        case .lodging: return TravelPlaceCategory.hotel.systemImage
        default: return kind.systemImage
        }
    }

    /// 地点的细分类别;不是地点时为 nil。
    public var placeCategory: TravelPlaceCategory? {
        kind == .place ? TravelPlaceCategory.classify(title: title, placeName: placeName) : nil
    }
}
