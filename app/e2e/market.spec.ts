// The market chart a public network shows, against stubs of Coinbase's REST candles and websocket ticker, so the suite
// reaches no outside service. The candles sit at the local feed's price.
import { expect, test } from '@playwright/test'
import { MARKET_PORT } from '../playwright.config'
import { MARKET_REST, MARKET_WS } from '../src/lib/market'
import { answerOf } from './chain'

test.use({ baseURL: `http://127.0.0.1:${MARKET_PORT}` })

test('draws market candles and follows the selected pair', async ({ page }) => {
  const prices = [Number(await answerOf(0)) / 1e8, Number(await answerOf(1)) / 1e8]
  const requested: string[] = []
  await page.route(`${MARKET_REST}/**`, async (route) => {
    const url = new URL(route.request().url())
    requested.push(`${url.pathname} ${url.searchParams.get('granularity')}`)
    const price = url.pathname.includes('ETH') ? prices[1] : prices[0]
    const bucket = Number(url.searchParams.get('granularity'))
    const end = Date.parse(url.searchParams.get('end')!) / 1000
    // Newest first, as Coinbase sends them: [time, low, high, open, close, volume]
    const rows = Array.from({ length: 120 }, (_, i) => {
      const t = end - (i + 1) * bucket
      const p = price * (1 + Math.sin(t / bucket / 7) * 0.004)
      return [t, p * 0.999, p * 1.001, p, p * 1.0005, 1]
    })
    await route.fulfill({ json: rows, headers: { 'access-control-allow-origin': '*' } })
  })
  const subscribed: string[] = []
  await page.routeWebSocket(MARKET_WS, (ws) => {
    ws.onMessage((raw) => {
      const msg = JSON.parse(String(raw)) as { product_ids: string[] }
      subscribed.push(...msg.product_ids)
      const product = msg.product_ids[0]
      const price = product === 'ETH-USD' ? prices[1] : prices[0]
      ws.send(JSON.stringify({ type: 'ticker', product_id: product, price: String(price * 1.003), time: new Date().toISOString() }))
    })
  })

  await page.goto('/')
  await page.getByText('Proof of concept, not audited').waitFor()
  await expect(page.locator('.chart-note')).toContainText('BTC-USD trades on Coinbase Exchange')
  await expect(page.getByRole('img', { name: /market candles from Coinbase BTC-USD/ })).toBeVisible()
  await expect(page.locator('.chart-state')).toHaveCount(0)
  await expect.poll(() => subscribed).toContain('BTC-USD')
  expect(requested).toContain('/products/BTC-USD/candles 60')

  await page.getByRole('button', { name: '5m', exact: true }).click()
  await expect.poll(() => requested).toContain('/products/BTC-USD/candles 300')

  await page.locator('.pair-button').click()
  await page.getByRole('option').filter({ hasText: 'ETH' }).getByRole('button').click()
  await expect(page.locator('.chart-note')).toContainText('ETH-USD trades on Coinbase Exchange')
  await expect.poll(() => subscribed).toContain('ETH-USD')
  await expect.poll(() => requested).toContain('/products/ETH-USD/candles 300')
  await expect(page.locator('.chart-state')).toHaveCount(0)
  if (process.env.SCREENSHOT_DIR) await page.screenshot({ path: `${process.env.SCREENSHOT_DIR}/market-chart.png` })
})
