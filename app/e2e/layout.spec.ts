// Every page fits a 360 px phone without horizontal scrolling. A table may scroll inside its own frame.
import { expect, test } from '@playwright/test'

for (const path of ['/', '/vault', '/positions', '/how-it-works']) {
  test(`${path} fits a 360 px screen`, async ({ page }) => {
    await page.setViewportSize({ width: 360, height: 780 })
    await page.goto(path)
    await page.getByText('Proof of concept, not audited').waitFor()
    await page.locator('main h1, main h2').first().waitFor()
    const widths = await page.evaluate(() => ({ scroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth }))
    expect(widths.scroll).toBeLessThanOrEqual(widths.client)
  })
}
