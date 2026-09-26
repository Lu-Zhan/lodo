import Foundation
import CoreFoundation

// 运行: swift ios/Tools/generate_pinyin_dict.swift
// GB2312 的 6763 个常用汉字由系统转写得到拼音;词组作为轻量高频补充。
let output = URL(fileURLWithPath: "ios/LodoKeyboard/PinyinDictionary.txt")
let frequent = "的一是不了在人有我他这中大来上国个到说们为子和你地出道也时年得就那要下以生会自着去之过家学对可她里后小么心多天而能好都然没日于起还发成事只作当想看文无开手十用主行方又如前所本见经头面公同三已老从动两长知民样现分将外但身些与高实向声车全信重儿物使工水电机名法新情总山话加间儿最美中国人民世界北京上海广州深圳今天明天工作学习生活时间提醒任务完成稍等"
var lines: [String] = []
let commonWords = "中国:zhong'guo:9000 人民:ren'min:8000 世界:shi'jie:7000 北京:bei'jing:9000 上海:shang'hai:8000 广州:guang'zhou:7000 深圳:shen'zhen:7000 今天:jin'tian:9000 明天:ming'tian:9000 工作:gong'zuo:8000 学习:xue'xi:7000 生活:sheng'huo:7000 时间:shi'jian:9000 提醒:ti'xing:8000 任务:ren'wu:8000 完成:wan'cheng:8000 稍等:shao'deng:8000 你好:ni'hao:9000 谢谢:xie'xie:9000 我们:wo'men:8000 他们:ta'men:7000 可以:ke'yi:8000 什么:shen'me:9000 怎么:zen'me:8000 现在:xian'zai:9000 一下:yi'xia:8000 这个:zhe'ge:9000 那个:na'ge:8000 没有:mei'you:8000 已经:yi'jing:8000 时候:shi'hou:8000 如果:ru'guo:8000 因为:yin'wei:8000 所以:suo'yi:8000 开始:kai'shi:8000 结束:jie'shu:8000 记一下:ji'yi'xia:9000 待办:dai'ban:9000 记忆:ji'yi:7000 助手:zhu'shou:7000 输入:shu'ru:7000 拼音:pin'yin:7000 键盘:jian'pan:7000 先:xian:9500 西安:xi'an:9000"
for item in commonWords.split(separator: " ") {
    let parts = item.split(separator: ":")
    if parts.count == 3 { lines.append("\(parts[1])\t\(parts[0])\t\(parts[2])") }
}
// 新版系统 Foundation 不再保证能直接用 GB2312 解码,由 Python 标准库列出
// GB2312 字符集;注音仍只用系统 CFStringTransform。
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
process.arguments = ["-c", "print(''.join(bytes([h,l]).decode('gb2312','ignore') for h in range(0xA1,0xF8) for l in range(0xA1,0xFF)))"]
let pipe = Pipe()
process.standardOutput = pipe
try process.run()
let characters = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
process.waitUntilExit()
for charValue in characters where charValue.unicodeScalars.first?.properties.isIdeographic == true {
        let char = String(charValue)
        let mutable = NSMutableString(string: char)
        guard CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false) else { continue }
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        let pinyin = (mutable as String).lowercased().replacingOccurrences(of: " ", with: "")
        guard pinyin.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            print("未转写: \(char) \(pinyin)")
            continue
        }
        let priority = frequent.contains(char) ? 5000 : 100
        lines.append("\(pinyin)\t\(char)\t\(priority)")
}
// 常见多音字在用户常见读音下也给出候选。
for (pinyin, char) in [("zhong", "重"), ("hang", "行"), ("le", "乐"), ("chang", "长"), ("de", "得"), ("di", "地"), ("hai", "还"), ("dou", "都"), ("zhe", "着")] {
    lines.append("\(pinyin)\t\(char)\t4500")
}
try lines.joined(separator: "\n").appending("\n").write(to: output, atomically: true, encoding: .utf8)
print("写入 \(lines.count) 条: \(output.path)")
