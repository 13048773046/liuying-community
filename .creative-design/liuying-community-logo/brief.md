# 任务 Brief：流萤社区 App Logo 主版本

## 主题与商品
- 主题：App 图标品牌识别（Android/iOS 桌面图标）
- 商品：无实体商品；核心对象为「流萤社区」App 品牌标识
- 品牌名（准确源文字）：流萤社区

## 需求来源（用户原话）
"你先生成一个和那个音乐 APP 类似的 LOGO，然后就用这个 logo 来打包出来。"

## 视觉参考（已核验）
音乐 App 图标（AppIcon-1024.png）：纯深黑背景 + 白色发光音符主体 + 发光小圆点，极简、中心构图、强对比。

## 指令合同
- operation: image_generate
- deliverable: App 图标 Logo 主版本（1:1，1024×1024）
- canvas: 1024×1024 正方形
- content_goal: 第一眼看到中央发光的萤火虫光点；随后看到环绕小星光与底部品牌名
- source_inputs: none（风格参考为已核验的音乐图标，文字描述继承）
- visual_thesis: 深黑底 + 白紫发光萤火虫 + 星芒环绕 = 流萤系列视觉家族 + 社区汇聚语义
- composition: 主体光点中心偏上（约 55%），品牌名居底（12% 区域），大负空间
- visual_language: 深黑底(#0D0D12) + 白→淡紫单色光效，克制辉光，锐利边缘，无杂色
- visible_text: "流萤社区"（白色无衬线、中粗、中轴对齐）
- must_not_include: 除品牌名外任何文字/水印/额外装饰/渐变背景
- quality_target: 1024px 清晰、轮廓锐利、光效不溢出画布

## 用途
生成后替换 Android mipmap 与 iOS AppIcon 全尺寸，重新打包 APK + 触发 CI 出 IPA。
