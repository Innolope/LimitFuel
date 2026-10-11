# LimitFuel Website

Landing page for LimitFuel macOS app.

## Structure

```
website/
└── index.html    - Single-page landing site with inline CSS
```

## Deployment

No LimitFuel website has been deployed. The inherited canonical URLs, sitemap,
social images and domain configuration refer to the upstream claudeusagebar.com
site. Configure a domain you own before publishing. Download links point to this
fork's build instructions until a signed release exists.

### Local Development

Simply open `index.html` in a browser:

```bash
open index.html
```

Or use a local server:

```bash
python3 -m http.server 8000
# Visit http://localhost:8000
```

## Technologies

- Pure HTML5
- Inline CSS (no external dependencies)
- Responsive design
- Dark theme
- Inter font from Google Fonts

## Features

- Hero section with download CTA
- Feature showcase
- Installation guide
- Screenshots section
- FAQ
- Footer with links

## Customization

All styles are inline in `index.html`. To customize:

1. Edit colors in CSS variables at top of `<style>` section
2. Update content in HTML sections
3. Replace links with your GitHub username/repo

## Future Enhancements

- [ ] Extract CSS to separate file (`assets/css/style.css`)
- [ ] Add images folder (`assets/images/`)
- [ ] Add JavaScript for animations
- [ ] Add analytics (optional)
- [ ] Add blog/changelog section
