# Provider marks

These monochrome marks identify the connected providers; they are not LimitFuel's
app branding. Claude/Anthropic and OpenAI retain their respective trademarks.

- ClaudeMark.svg: [Simple Icons Claude asset](https://github.com/simple-icons/simple-icons/blob/develop/icons/claude.svg),
  retrieved 2026-10-11. Simple Icons SVG assets are distributed under CC0.
- OpenAIMark.svg: unaltered black Blossom path from the official
  [Blossom Light SVG](https://images.ctfassets.net/kftzwdyauwt9/3hUGLn3ypllZ0oa01qOYVq/28e8188e6f11b84c3e876569d492734f/Blossom_Light.svg),
  retrieved 2026-10-11, excluding the construction-guide illustration beside it.
  [OpenAI design guidelines](https://openai.com/brand/).

The matching PDFs are vector exports for AppKit. Regenerate with
`python3 tools/export_provider_marks.py` (developer-only ReportLab dependency;
not needed to build or run the app). The exporter preserves the SVG path geometry.
