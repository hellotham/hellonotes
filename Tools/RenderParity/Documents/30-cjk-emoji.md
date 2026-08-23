# 多言語のノート — mixed scripts

日本語の段落です。これは折り返しの挙動を確かめるための、そこそこ長い文章で、
句読点や括弧（かっこ）を含みます。エディタとプレビューが同じ高さになるかどう
かが問題です。

中文段落：这一段用来检查中日韩文字的换行与行高。标点符号、括号（如这个）以及
数字 12345 都混在一起，看看两个渲染器是否一致。

한국어 문단입니다. 한글은 음절 단위로 줄바꿈이 일어나므로, 라틴 문자와 섞였을
때 줄 높이가 달라지는지 확인할 필요가 있습니다.

## Emoji

Shipping status: 🚢 ✅ 🎉 — and a family, which is several code points joined:
👨‍👩‍👧‍👦. A flag: 🇦🇺. A skin-tone modifier: 👋🏽.

- ✅ Done
- 🚧 In progress
- ❌ Blocked

## Combining marks

Composed vs decomposed, which look identical and are not:

- `café` — one code point for the é
- `café` — `e` followed by U+0301
- `Ω` vs `Ω` — Ohm sign and Greek capital omega
- Vietnamese stacks: `nghiêng`, `tiếng Việt`, `Nguyễn`

> 「引用の中の日本語」— a quote in another script, with 括弧 inside it.

| Script | Sample | Note |
| --- | --- | --- |
| Japanese | 見出し | Mixed with `code` |
| Korean | 제목 | |
| Emoji | 🎉🚀 | Two of them |
