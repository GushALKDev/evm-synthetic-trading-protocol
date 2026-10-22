// Captures every page at desktop and phone widths, in light and dark, for a visual review.
// SCREENSHOT_DIR=<dir> npx playwright test e2e/screenshots.spec.ts
import { test } from '@playwright/test'

const dir = process.env.SCREENSHOT_DIR
const pages = [
  ['trade', '/'],
  ['earn', '/earn'],
  ['liquidations', '/liquidations'],
  ['how', '/how-it-works'],
] as const
const sizes = [
  ['desktop', 1280, 900],
  ['phone', 360, 780],
] as const

test.skip(!dir, 'SCREENSHOT_DIR not set')

for (const scheme of ['light', 'dark'] as const) {
  for (const [size, width, height] of sizes) {
    for (const [name, path] of pages) {
      test(`${name} ${size} ${scheme}`, async ({ page }) => {
        await page.emulateMedia({ colorScheme: scheme })
        await page.setViewportSize({ width, height })
        await page.goto(path)
        await page.getByText('Proof of concept, not audited').waitFor()
        await page.locator('main h1, main h2, main .market-bar').first().waitFor()
        await page.waitForTimeout(2500)
        await page.screenshot({ path: `${dir}/${name}-${size}-${scheme}.png`, fullPage: true })
      })
    }
  }
}
