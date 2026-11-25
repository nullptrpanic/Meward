// Run on a development Mac. See docs/name-recognition.md for the pinned dictionary and commands.
import CreateML
import CryptoKit
import Foundation
import NaturalLanguage

guard CommandLine.arguments.count == 5 else {
    fatalError("Usage: swift tools/train-name-model.swift dict.txt zh-CN.jsonl zh_train.conll output.mlmodel")
}
let source = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let digest = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
precondition(digest == "7197c3211ddd98962b036cdf40324d1ea2bfaa12bd028e68faa70111a88e12a8", "Unexpected dictionary version")

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64 = 20261124
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = (state ^ (state >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}
var random = SeededGenerator()
func pick<T>(_ choices: [T]) -> T { choices.randomElement(using: &random)! }
let surnames = Array("赵钱孙李周吴郑王冯陈褚卫蒋沈韩杨朱秦尤许何吕施张孔曹严华金魏陶姜戚谢邹喻柏水窦章云苏潘葛奚范彭郎鲁韦昌马苗方俞任袁柳鲍史唐费薛雷贺倪汤罗毕郝安常傅齐康伍余顾孟平黄和穆萧尹姚邵汪祁毛禹狄米贝明臧戴宋庞熊纪舒屈项董梁杜阮蓝闵席季麻强贾路娄危江童颜郭梅盛林刁钟徐邱骆高夏蔡田樊胡凌霍虞万支柯管卢莫房解应宗丁宣邓郁单杭洪包诸左石崔吉龚程邢裴陆翁卓温庄阎慕连廖曾谭易赖黎龙段樊洪叶肖邝隋佟麦区仇覃殷闫涂")
let compound = ["欧阳", "司马", "上官", "诸葛", "东方", "司徒", "夏侯", "皇甫", "慕容", "南宫", "令狐", "宇文"]
let given = Array("敏静丽强磊洋勇军杰娟涛超明芳平刚桂英俊秀伟华建国晓春小秋冬雨晴雪霖霏露风枫林禾宁嘉欣佳思涵晨辰星月云川海山竹松柏安乐阳清青言一可子予之允禾如心念伊依亦景书知行远泽睿博文武诗雅昊宇轩宸哲凯珂铭航帆翰浩楠桐梓楷琦琪瑾瑜瑞琳玲婉莹颖妍婧茵芷萱桦霁澄舒维时新初然然川为奕南北尚成江淮锦程欢萌玥琛佩宏兰彬达元梦恩熙天恒君灿彤曼立悦鹏怡毅斌晗宁菲蔚彭岳悦培懿峰可宜和礼智欣凡星")
let single = Set(surnames)
var annotatedNames: [String] = []
var givenNames: [String] = []
var otherWords: [String] = []
var commonWords: [String] = []
var placeNames: [String] = []
var organisationNames: [String] = []
for line in String(decoding: source, as: UTF8.self).split(separator: "\n") {
    let fields = line.split(separator: " ")
    guard fields.count == 3, let frequency = Int(fields[1]), frequency >= 5 else { continue }
    let word = String(fields[0])
    guard (2...6).contains(word.count),
          word.unicodeScalars.allSatisfy({ (0x3400...0x9fff).contains($0.value) }) else { continue }
    if frequency >= 30 {
        if fields[2] == "ns" { placeNames.append(word) }
        if fields[2] == "nt" { organisationNames.append(word) }
    }
    switch fields[2] {
    case "nr", "nrfg":
        let familyLength = compound.first(where: word.hasPrefix)?.count ?? (single.contains(word.first!) ? 1 : 0)
        let rest = word.dropFirst(familyLength)
        if familyLength > 0, (1...2).contains(rest.count) { givenNames.append(String(rest)) }
    case "n", "v", "a", "i", "l", "ns", "nt", "t", "d", "vn", "r", "nz", "ad", "an", "vd", "z", "c", "p":
        otherWords.append(word)
        if frequency >= 100 { commonWords.append(word) }
    default: break
    }
}
func sampleName() -> String {
    if Int.random(in: 0..<4, using: &random) == 0 { return pick(annotatedNames) }
    let family = Int.random(in: 0..<16, using: &random) == 0 ? pick(compound) : String(pick(surnames))
    if Bool.random(using: &random) { return family + pick(givenNames) }
    let length = Int.random(in: 0..<4, using: &random) == 0 ? 1 : 2
    return family + String((0..<length).map { _ in pick(given) })
}

// Each placeholder is a separate person. Punctuation, ordinary chat text, locations and
// organisations are outside the entities. Use one token per character at training and inference.
let messages = [
    "§", "§", "§", "§", "@§", "§：", "§ 09:41", "收到，谢谢§。", "我是§", "大家好我叫§",
    "让§帮忙看一下", "§刚刚加入群聊", "刚才遇到了§", "§已经收到文件了", "请发给§确认", "§您好",
    "§老师今天值班", "明天请§参加会议", "§回复了你的消息", "麻烦§看一下附件", "等§回来再说",
    "可以问问§吗", "§把照片分享给了§", "我和§在路上", "§与§报名了", "§、§和§都到了",
    "谢谢§，下次见！", "发件人 §", "来自§的消息", "请§签字", "§在北京等你", "下午见，§",
    "主讲人：§", "这个问题由§负责", "负责人§已提交申请", "§ / §", "§完成了交接", "跟§说一声",
    "麻烦转告§一声", "§和§", "§说可以", "请§明早联系我", "刚联系过§了", "同事§发来了材料",
    "§发起语音通话", "联系§和§", "§ invited you", "09:30 §", "好的§，周一见", "刚收到§的回复",
    "这位是§。", "问过§了吗？", "§去过上海", "好的，我转给§。", "§｜在线", "§明天下午有空吗"
]
let chatText = """
    周一到周五 下午见 明早再说 周末愉快 有空聊聊 大家好 收到了 好的谢谢 谢谢大家 没问题 正在输入
    文件传输助手 消息通知 群聊记录 微信支付 聊天记录 入群申请 快递通知 已经发出 好友申请 语音消息
    明天下午 截图预览 图片已保存 早上好 中午好 晚安 明天见 等会儿见 下班了吗 在路上 先去吃饭
    明天开会 工单进度 今天出发 明天回复 公司地址 办公时间 联系电话 手机号码 身份证号 身份证号码
    姓名 性别 民族 住址 北京 上海 广州 杭州 深圳 浙江大学 中国银行 北京大学 公司群 通讯录
    客户服务 开会通知 在线客服 稍后回复 好的收到 地址栏 返回主页 微信团队 系统通知 未读消息
    林业局 林业公园 林场 林木 林业研究所 陈列室 陈旧照片 周报 周末 周四下午 马路 马上出发
    高楼 高兴 高铁站 白天 白云路 会议室 小组会议 文件已发 申请材料 上海分公司 周边服务
    """
typealias Example = (tokens: [String], labels: [String])
var examples: [Example] = []
func appendMessage(_ template: String, nameForSlot: () -> String = sampleName) {
    var tokens: [String] = [], labels: [String] = []
    for character in template {
        if character == "§" {
            let name = nameForSlot()
            tokens += name.map { String($0) }
            labels += ["B"] + Array(repeating: "I", count: name.count - 2) + ["E"]
        } else {
            tokens.append(character.isWhitespace ? "|" : String(character))
            labels.append("O")
        }
    }
    examples.append((tokens, labels))
}
func appendNegative(_ text: String) {
    examples.append((text.map { $0.isWhitespace ? "|" : String($0) }, Array(repeating: "O", count: text.count)))
}
// Learn both name boundaries and non-person entities from human-labelled Chinese text.
let entityData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
precondition(SHA256.hash(data: entityData).map { String(format: "%02x", $0) }.joined()
    == "9e53891573f54e975812fa4703eddcd59f017dc833d7d8b0471c92b6fa6e3aad", "Unexpected MultiCoNER version")
let entityText = String(decoding: entityData, as: UTF8.self)
let simplified = entityText.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false)!
let personTypes: Set<Substring> = ["Scientist", "Artist", "Athlete", "Politician", "Cleric", "SportsManager", "OtherPER"]
var annotatedSentences: [String] = []
for sentence in simplified.components(separatedBy: "\n\n") {
    var example: Example = ([], [])
    var person = ""
    var pattern = ""
    func finishPerson() {
        guard !person.isEmpty else { return }
        // Reuse annotated people for chat augmentation. A dictionary proper-noun tag alone
        // can also describe ordinary vocabulary and is unreliable as a personal-name label.
        if (2...4).contains(person.count), person.unicodeScalars.allSatisfy({ $0.properties.isIdeographic }),
           single.contains(person.first!) || compound.contains(where: person.hasPrefix) { annotatedNames.append(person) }
        pattern += "§"
        example.tokens += person.map { String($0) }
        if person.count > 1 {
            example.labels += ["B"] + Array(repeating: "I", count: person.count - 2) + ["E"]
        } else { example.labels.append("O") }
        person = ""
    }
    for line in sentence.split(separator: "\n") where !line.hasPrefix("#") {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count == 4 else { continue }
        let word = fields[0], tag = fields[3]
        let isPerson = personTypes.contains(tag.dropFirst(2))
        if !isPerson || tag.hasPrefix("B-") { finishPerson() }
        if isPerson { person += word } else {
            example.tokens += word.map { String($0) }
            example.labels += Array(repeating: "O", count: word.count)
            pattern += word
        }
    }
    finishPerson()
    if !example.tokens.isEmpty {
        // Keep natural sentences represented alongside the generated chats and forms.
        examples.append(contentsOf: repeatElement(example, count: pattern.contains("§") ? 2 : 3))
    }
    if pattern.contains("§") { annotatedSentences.append(pattern) }
}
for pattern in annotatedSentences {
    for _ in 0..<2 { appendMessage(pattern) }
}
// Use the labelled person slots in MASSIVE's training partition as real sentence contexts.
// Substitute generated names so that learning the boundaries does not depend on memorizing a contact.
let corpus = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
precondition(SHA256.hash(data: corpus).map { String(format: "%02x", $0) }.joined()
    == "992bf0bef3d678f08c27e514739bc851163e8f40f530bfb4d5970a2c24408ace", "Unexpected MASSIVE version")
let slot = try NSRegularExpression(pattern: #"\[\s*(\w+)\s*:\s*([^\]]+?)\s*\]"#)
for line in corpus.split(separator: 10) {
    guard let record = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
          record["partition"] as? String == "train", let annotated = record["annot_utt"] as? String,
          !annotated.contains("[artist_name") else { continue }
    let message = NSMutableString(string: annotated)
    for match in slot.matches(in: annotated, range: NSRange(location: 0, length: message.length)).reversed() {
        let kind = message.substring(with: match.range(at: 1))
        let value = message.substring(with: match.range(at: 2))
        let possessive = value.hasSuffix("的") ? "的" : ""
        message.replaceCharacters(in: match.range, with: kind == "person" ? "§" + possessive : value)
    }
    let template = (message as String).filter { !$0.isWhitespace }
    for _ in 0..<(template.contains("§") ? 7 : 1) { appendMessage(template) }
}
for _ in 0..<19000 { appendMessage(pick(messages)) }
for _ in 0..<9000 { appendMessage("§") }
let prefixes = ["", "请", "问问", "听说", "我找", "刚好碰到", "我和", "昨天", "告诉", "联系一下", "谢谢", "麻烦",
                "转交给", "文件交由", "经办人是", "让", "托", "请通知", "记得提醒", "刚才问过"]
let suffixes = ["", "今天有空吗", "周五来学校", "明天再来", "刚上线", "周三值班", "会尽快回复", "正在开会", "下午到",
                "的照片", "是我同事", "过来一下", "已经看了", "怎么说", "回来了吗", "上周出差", "也在这里", "，好的",
                "吧", "复核一下", "来签收", "一起确认", "了。"]
for _ in 0..<15000 {
    let subject = pick(["§", "§", "§", "§和§", "§、§", "§跟§", "§约§", "§通知了§", "§回复§", "§转给§"])
    appendMessage(pick(prefixes) + subject + pick(suffixes))
}
otherWords.shuffle(using: &random)
for word in otherWords.prefix(28000) { appendNegative(word) }
for word in commonWords { appendNegative(word) }

// Requests and lists can introduce either people or ordinary phrases. Include both in
// the same contexts, including a line that wraps immediately after a modifier.
let modifiers = ["严格", "认真", "及时", "仔细", "逐项", "依次", "按时", "如实", "务必", "正确", "合理", "定期", "尽快", "充分", "妥善"]
let instructions = ["遵循指引", "遵照要求", "遵守规定", "执行标准", "阅读说明", "核对信息", "填写表格", "保存文件",
                    "观察变化", "检查设备", "清点物品", "确认用法", "登记信息", "复核材料", "准备证件", "咨询医生"]
let introductions = ["", "请", "应当", "需要", "注意事项：请", "1. ", "具体要求：", "登记时应", "提交前请", "，请", " 。请"]
let listWords = ["头痛", "咳嗽", "发热", "乏力", "口干", "口苦", "恶心", "呕吐", "红肿", "胸闷", "眩晕", "瘙痒", "过敏",
                 "日期", "地址", "数量", "金额", "规格", "材料", "型号", "尺寸", "颜色", "进度", "期限", "状态", "类别"]
for _ in 0..<7500 {
    let beginning = pick(introductions) + pick(modifiers)
    let instruction = pick(instructions)
    appendNegative(pick([beginning, beginning + instruction, beginning + instruction + "。", instruction + "。"]))
    let items = [pick(listWords), pick(listWords), pick(listWords)].joined(separator: pick(["、", "，", " / "]))
    appendNegative(pick(["", "表格 ", "常见情况 ", "包括：", "请核对"]) + items + pick(["", "。", "等。"]))
    appendMessage(pick(["", "请", "已通知", "提醒"]) + "§" + pick(["，请", "需要", "已", "应"]) + pick(modifiers) + instruction)
}
for phrase in chatText.split(whereSeparator: \.isWhitespace) {
    for _ in 0..<16 { appendNegative(String(phrase)) }
    for _ in 0..<12 { appendNegative(pick(["关于", "看看", "这里是", "", "请查看"]) + phrase + pick(["开放了", "有更新", "的通知", "已经收到", ""])) }
}
// OCR rows can join a short heading with the text in the adjacent column. Ordinary
// verb–noun pairs inside the heading should keep their boundaries in that context.
let topics = ["申请", "办理", "使用", "检查", "复查", "操作", "填写", "处理", "复核", "报修", "说明", "登记", "维护", "观察", "提交", "记录", "检测"]
let details = ["时间", "时机", "周期", "流程", "说明", "要求", "方法", "条件", "事项", "标准", "文字", "内容", "材料", "日期", "地点", "步骤", "结果", "人员"]
let qualifiers = ["", "普通", "一般", "其他", "详细", "具体", "基本", "日常", "首次", "常规"]
for _ in 0..<7000 {
    let heading = pick(qualifiers) + pick(topics) + pick(details)
    let separator = pick([" ", " ", "：", "　"])
    appendNegative(pick([heading, heading + separator + pick(instructions) + "。", heading + separator + pick(commonWords)]))
    if Int.random(in: 0..<3, using: &random) == 0 {
        appendMessage(heading + separator + pick(["由§负责。", "§已经确认", "请§办理", "请交给§。"]))
    }
}
// Include less frequent surnames in free text as well as forms. All names here
// are generated from public vocabulary, independent of any image being edited.
let additionalFamilies = Array("祝翟缪邬邰芮蔺荀卞郜瞿鄢胥仝宓蒯仉阚郇綦苟丛闻匡晏茹练屠栾宁庹")
let givenStarts = givenNames.compactMap(\.first)
let givenEnds = givenNames.compactMap(\.last)
func variedName() -> String {
    let family = Bool.random(using: &random) ? String(pick(additionalFamilies)) : String(pick(surnames))
    if Bool.random(using: &random) { return family + pick(givenNames) }
    return family + String([pick(givenStarts), pick(givenEnds)])
}
let roles = ["承办人", "经办人", "申请人", "填表人", "复核人", "受托人", "见证人", "签收人", "登记员", "记录人"]
let personFields = ["姓名", "姓 名", "户主姓名", "户名", "收件人", "联系人"]
let blanks = ["未提供", "暂缺", "待填写", "尚未填写", "请在此填写", "不详", "无", "不适用", "待核实", "请留空", "暂无记录", "________"]
let ambiguousNames = ["严格", "何时", "何地", "田野", "白露", "高原", "江南", "安心", "周全", "方向", "夏天"]
let spaces = ["", " ", "：", ": ", "　"]
for _ in 0..<8000 {
    let role = pick(roles) + pick(["", "签章", "签字", "签名", "（签名）"])
    let field = pick([role, pick(personFields)]) + pick(spaces)
    let ending = pick(["", "", "。", "　登记日期", " 2022年6月", " 已签收"])
    let people = pick(["§", "§", "§", "§", "§、§", "§和§"])
    appendMessage(field + people + ending) {
        Int.random(in: 0..<8, using: &random) == 0 ? pick(ambiguousNames) : variedName()
    }
    appendNegative(field + pick(blanks))
    appendMessage(pick(messages), nameForSlot: variedName)
}
// Vary both sides of time/place questions, including fragments left at OCR
// word breaks. A person mentioned in or after a question remains a person.
let times = ["何时", "何 时", "何年何月", "何日", "哪一年", "什么时候"]
let places = ["何地", "何处", "哪里", "哪一地区"]
let origins = ["由", "从", "自", "在", " 于", "、由", "，从", " "]
let actions = ["迁来", "迁入", "转入", "来到", "办理", "登记", "抵达", "返回", "签发"]
let destinations = ["本市", "本址", "此地", "当地", "本区", "本单位", "学校", ""]
for _ in 0..<5000 {
    let time = pick(times), place = pick(places), origin = pick(origins)
    let ending = pick(actions) + pick(destinations)
    let question = pick([time + origin + place, time + pick(["、", " ", "，"]) + place, origin + place, time, place])
    appendNegative(pick(["", "", "请问", "登记事项 "]) + question + pick(["", ending, ending + "？"]))
    appendNegative(time + origin + pick(["", " ", " 来" + pick(destinations)]))
    appendMessage(pick(["§" + question + ending + "？", question + ending + "　§已签收", "请问§" + time + ending]))
}
// Balance ambiguous surface forms in personal contexts against the same
// characters used as ordinary words. Separators are part of the OCR input.
for name in ambiguousNames {
    for personField in personFields + roles {
        for separator in spaces {
            for _ in 0..<4 {
                appendMessage(personField + separator + "§" + pick(["", "", "。", "　性别", " 已签收"])) { name }
            }
        }
    }
    for _ in 0..<100 {
        appendMessage(pick(["我叫§", "由§签收。", "大家都认识§", "他的名字是§", "这位是§。", "§已收到材料。"])) { name }
    }
}
// A surname character is also common inside ordinary words. Pair those words
// with surrounding prose so a span need not start or end at a family character.
let families = single.union(additionalFamilies)
for word in commonWords where families.contains(word.first!) || families.contains(word.last!) {
    appendNegative(pick(["注意", "有关", "记录", "保持", "请检查", "包括", ""]) + word + pick(["", "。", "的情况", "记录"]))
}
let units = ["分钟", "小时", "天", "周", "个月", "秒钟"]
let verbs = ["服用", "完成", "送达", "登记", "生效", "检查", "记录", "联系", "确认", "复核"]
let qualities = ["卫生", "安全", "清洁", "质量", "整洁"]
for _ in 0..<3000 {
    let duration = String(Int.random(in: 1...90, using: &random)) + pick(units)
    appendNegative(pick(["", "约", "每", "需等待", "提前"]) + duration + pick(["", "后", "内"]) + pick(verbs) + "。")
    let requirement = pick(["注意", "保持", "保障", "定期检查"]) + pick(["个人", "环境", "食品", "公共", "室内", ""]) + pick(qualities)
    appendNegative(requirement + "。")
    appendNegative(pick(times) + pick(["、", " ", "，", "由"]) + pick(places) + pick([" ", ""]) + pick(verbs))
    appendMessage("§" + pick(["确认后", "核对后", "已", "要求"]) + pick(modifiers) + pick(["执行", "实行", "办理", "保管"]) + "。")
}
// Keep place names and organisation names distinct from people when a
// register or a stamp shares a line with someone mentioned in the document.
let ordinaryFields = ["政治面貌", "宗教信仰", "文化程度", "婚姻状况", "职业", "服务处所", "工作单位", "登记机关", "签发机关", "籍贯", "出生地", "户主关系", "申请事由", "证件类型", "有效期限", "常住人口", "人口变动"]
let stampTypes = ["户口", "业务", "档案", "财务", "审批", "登记", "行政", "合同"]
let streetStems = ["青松", "和平", "云景", "南湖", "新河", "东风", "长兴", "向阳", "滨江", "梧桐", "丰收", "文昌"]
for _ in 0..<4500 {
    let road = pick(streetStems) + pick(["路", "村", "街", "巷", "弄", "新村", "大道", "里", "花园", "小区"])
    let address = pick(["", pick(placeNames)]) + road + String(Int.random(in: 1...500, using: &random)) + "号"
    let office = pick([pick(organisationNames), pick(placeNames) + pick(["办事处", "公安局", "服务站"])])
    let stamp = pick(stampTypes) + pick(["专用", "专用章", "公章", "登记章"])
    appendNegative(pick(["", "住所", "出生地", "住址：", "登记地址 "]) + address)
    appendNegative(pick([office + " " + stamp, stamp, pick(ordinaryFields), pick(ordinaryFields) + pick(spaces) + pick(["无", office, "未填写", pick(ordinaryFields)])]))
    appendMessage(pick(["§住在" + address, office + "　§签字", "请§核对" + pick(ordinaryFields), pick(ordinaryFields) + "　§已确认"]))
}
examples.shuffle(using: &random)
let tagger = try MLWordTagger(trainingData: examples, parameters: .init(
    validation: .none, algorithm: .crf(revision: 1), language: .simplifiedChinese))
let metadata = MLModelMetadata(author: "Meward", shortDescription: "Simplified Chinese personal-name spans in OCR text. Character-level B/I/E/O tags.",
    version: "3", additional: ["Training": "Synthetic chats, questions and forms, MultiCoNER v2 and MASSIVE 1.1 (CC BY 4.0), and jieba (MIT). See NameModelNotices.txt."])
try tagger.write(toFile: CommandLine.arguments[4], metadata: metadata)
