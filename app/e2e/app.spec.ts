// Every user action of the demo, driven through the interface against a local chain with the wagmi mock connector.
// Run after ./scripts/local-chain.sh:  npx playwright test e2e/app.spec.ts
// The suite reverts the chain to a snapshot when it finishes, so it can run again.
import { expect, test, type Page } from '@playwright/test'
import { E2E_ACCOUNT } from '../playwright.config'
import { makeStale, movePrice, realisedRatio, refreshFeeds, rpcCall, unlockTime, warp, warpTo, whaleWins } from './chain'

test.describe.configure({ mode: 'serial' })

let page: Page
let snapshot: unknown

const toast = (title: string | RegExp) => page.locator('.toast-title', { hasText: title })
const errorToast = () => page.locator('.toast[data-tone="error"]')
const ticket = () => page.locator('#trade')
const lastPosition = () => page.locator('[data-testid^="position-"]').first()

/** With SCREENSHOT_DIR set, captures the current page at desktop and phone widths, light and dark */
async function shot(name: string) {
  const dir = process.env.SCREENSHOT_DIR
  if (!dir) return
  for (const scheme of ['light', 'dark'] as const) {
    for (const [size, width] of [['desktop', 1280], ['phone', 360]] as const) {
      await page.emulateMedia({ colorScheme: scheme })
      await page.setViewportSize({ width, height: 800 })
      await page.waitForTimeout(300)
      await page.screenshot({ path: `${dir}/${name}-${size}-${scheme}.png`, fullPage: true })
    }
  }
  await page.emulateMedia({ colorScheme: 'light' })
  await page.setViewportSize({ width: 1280, height: 720 })
}

/** Dismisses every toast, so the next expectation waits for a toast the next action raises */
async function clearToasts() {
  const buttons = page.locator('.toast button[aria-label="Dismiss"]')
  while ((await buttons.count()) > 0) await buttons.first().click()
}

/**
 * Moves to a page the way a visitor's click does, without a reload: the mock connector does not reconnect after one.
 * The app polls the chain, so state changed from the test shows up within a refresh.
 */
async function go(path: string) {
  if (page.url() === 'about:blank') await page.goto(path)
  else
    await page.evaluate((href) => {
      window.history.pushState(null, '', href)
      window.dispatchEvent(new PopStateEvent('popstate'))
    }, path)
  await page.getByText('Proof of concept, not audited').waitFor()
  await page.locator('main h1, main h2').first().waitFor()
  await clearToasts()
}

async function open(pair: string, side: 'Long' | 'Short', collateral: string, leverage: string) {
  await go('/')
  await ticket().getByRole('button', { name: pair, exact: true }).click()
  await ticket().locator('.side', { hasText: side }).click()
  await page.locator('#collateral').fill(collateral)
  await ticket().getByRole('button', { name: leverage, exact: true }).click()
  await expect(ticket().getByText('Entry price')).toBeVisible()
  await ticket().getByRole('button', { name: new RegExp(`^(Approve and )?open ${side.toLowerCase()}$`, 'i') }).click()
  await expect(toast(`${side} opened`)).toBeVisible()
  const card = lastPosition()
  await expect(card).toContainText(`${side} ${leverage}`)
  return Number((await card.getAttribute('data-testid'))!.replace('position-', ''))
}

test.beforeAll(async ({ browser }) => {
  snapshot = await rpcCall('evm_snapshot')
  await refreshFeeds()
  page = await browser.newPage()
})

test.afterAll(async () => {
  await page.close()
  if (snapshot) await rpcCall('evm_revert', [snapshot])
})

test('reads the whole protocol without a wallet', async () => {
  await go('/')
  await expect(page.getByRole('heading', { level: 1 })).toContainText('against one USDC vault')
  await expect(page.getByText('The vault holds')).toBeVisible()
  await expect(page.locator('.market')).toHaveCount(3)
  await expect(page.getByRole('button', { name: 'Connect wallet to trade' })).toBeVisible()

  await go('/positions')
  await expect(page.getByText('4 open, 0 ready for a keeper')).toBeVisible()
  await expect(page.getByText('seed trade').first()).toBeVisible()

  await go('/vault')
  await expect(page.getByRole('heading', { name: 'Solvency layers' })).toBeVisible()

  await go('/how-it-works')
  await expect(page.getByRole('heading', { name: 'Where the prices come from' })).toBeVisible()
})

test('connects the wallet and claims test USDC, warning about gas only once the balance is known', async () => {
  await go('/')
  await page.locator('.site-header').getByRole('button', { name: 'Connect wallet' }).click()
  await page.getByRole('button', { name: 'Mock Connector' }).click()
  await expect(page.locator('.site-header .mono')).toHaveText(`${E2E_ACCOUNT.slice(0, 6)}…${E2E_ACCOUNT.slice(-4)}`)

  // No ETH: the faucet says so
  const balance = await rpcCall('eth_getBalance', [E2E_ACCOUNT, 'latest'])
  await rpcCall('anvil_setBalance', [E2E_ACCOUNT, '0x0'])
  await page.locator('.site-header').getByRole('button', { name: 'Get test USDC' }).click()
  await expect(page.locator('.dialog').getByText('Your wallet has no Local anvil ETH')).toBeVisible()
  await rpcCall('anvil_setBalance', [E2E_ACCOUNT, balance])
  await expect(page.locator('.dialog').getByText('Your wallet has no Local anvil ETH')).toBeHidden()

  await page.getByRole('button', { name: 'Claim 10,000 test USDC' }).click()
  await expect(toast('Test USDC claimed')).toBeVisible()
  await expect(page.locator('.dialog')).toContainText('10,000.00')
  // A second claim the same day is refused before anything is sent
  await expect(page.getByRole('button', { name: 'Claim 10,000 test USDC' })).toBeDisabled()
  await expect(page.getByText('You already claimed today')).toBeVisible()
  await page.getByRole('button', { name: 'Close' }).click()
})

test('opens a long with an approval, sets a take profit, and a keeper executes it', async () => {
  const id = await open('BTC/USD', 'Long', '1000', '10x')

  const card = page.locator(`[data-testid="position-${id}"]`)
  await card.getByRole('button', { name: 'Take profit and stop loss' }).click()
  // The editor's inputs and buttons stay inside the card
  const cardBox = (await card.boundingBox())!
  for (const button of await card.getByRole('button', { name: 'Clear' }).all()) {
    const box = (await button.boundingBox())!
    expect(box.x + box.width).toBeLessThanOrEqual(cardBox.x + cardBox.width)
  }
  // Below the current price: refused in the form, before anything is sent
  await card.locator(`#tp-${id}`).fill('99000')
  await expect(card.getByText('Take profit must be above the current price.')).toBeVisible()
  await expect(card.getByRole('button', { name: 'Set' }).first()).toBeDisabled()
  await card.locator(`#tp-${id}`).fill('101000')
  await card.getByRole('button', { name: 'Set' }).first().click()
  await expect(toast('Take profit set')).toBeVisible()
  await expect(card).toContainText('$101,000.00')
  if (process.env.SCREENSHOT_DIR) {
    await card.getByRole('button', { name: 'Take profit and stop loss' }).click()
    await page.locator('#collateral').fill('250')
    await shot('connected-trade')
    await page.locator('#collateral').fill('')
  }

  await movePrice(0, 150n)
  await go('/positions')
  const row = page.locator(`[data-testid="row-${id}"]`)
  await expect(row).toContainText('Take profit reached')
  await row.getByRole('button', { name: /Execute, earn/ }).click()
  await expect(toast(`Take profit of #${id} executed`)).toBeVisible()
  await expect(row).toHaveCount(0)
})

test('liquidates a short after the price moves against it', async () => {
  const id = await open('ETH/USD', 'Short', '1000', '50x')
  await movePrice(1, 300n)
  await go('/positions')
  const row = page.locator(`[data-testid="row-${id}"]`)
  await expect(row).toContainText('Liquidatable')
  await shot('connected-positions')
  await row.getByRole('button', { name: /Liquidate, earn/ }).click()
  await expect(toast(`Position #${id} liquidated`)).toBeVisible()
  await expect(row).toHaveCount(0)
})

test('closes a position at the payout the card shows', async () => {
  const id = await open('LINK/USD', 'Long', '500', '5x')
  const card = page.locator(`[data-testid="position-${id}"]`)
  await expect(card).toContainText('If closed now')
  await card.getByRole('button', { name: 'Close position' }).click()
  await expect(toast(`Position #${id} closed`)).toBeVisible()
  await expect(card).toHaveCount(0)
})

test('decodes a revert into a sentence when the Chainlink anchor goes stale', async () => {
  const id = await open('ETH/USD', 'Long', '1000', '50x')
  await movePrice(1, -300n)
  await makeStale(1)

  await go('/')
  await expect(page.getByText('Chainlink feed has not updated within')).toBeVisible()
  await go('/positions')
  const row = page.locator(`[data-testid="row-${id}"]`)
  await row.getByRole('button', { name: /Liquidate, earn/ }).click()
  await expect(errorToast()).toContainText(`Liquidate #${id} failed`)
  await expect(errorToast()).toContainText('The Chainlink ETH/USD feed last updated')

  await refreshFeeds()
  await row.getByRole('button', { name: /Liquidate, earn/ }).click()
  await expect(toast(`Position #${id} liquidated`)).toBeVisible()
})

test('deposits, cancels a withdrawal, then withdraws after the lock', async () => {
  await go('/vault')
  await page.locator('#deposit').fill('2000')
  await expect(page.getByText('Shares received')).toBeVisible()
  await page.getByRole('button', { name: /^(Approve and )?deposit USDC$/i }).click()
  await expect(toast('USDC deposited')).toBeVisible()
  await expect(page.getByText('Providing liquidity')).toBeVisible()

  await page.getByRole('tab', { name: 'Withdraw' }).click()
  await page.locator('.action').getByRole('button', { name: 'Max' }).click()
  await page.getByRole('button', { name: 'Request withdrawal' }).click()
  await expect(toast('Withdrawal requested')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Not unlocked yet' })).toBeDisabled()
  await clearToasts()
  await page.getByRole('button', { name: 'Cancel request' }).click()
  await expect(toast('Request cancelled')).toBeVisible()

  await clearToasts()
  await page.locator('.action').getByRole('button', { name: 'Max' }).click()
  await page.getByRole('button', { name: 'Request withdrawal' }).click()
  await expect(toast('Withdrawal requested')).toBeVisible()
  await expect(page.getByRole('button', { name: 'Not unlocked yet' })).toBeDisabled()
  await shot('connected-vault-request')

  await warpTo((await unlockTime(E2E_ACCOUNT)) + 60n)
  await go('/vault')
  await page.getByRole('tab', { name: 'Withdraw' }).click()
  await page.getByRole('button', { name: 'Withdraw USDC' }).click()
  await expect(toast('USDC withdrawn')).toBeVisible()
  await expect(page.getByText('No vault shares')).toBeVisible()
})

test('opens a bonding round when the vault is short, bonds and claims', async () => {
  await whaleWins()
  expect(await realisedRatio()).toBeLessThan(95n * 10n ** 16n)

  await go('/vault')
  await page.getByRole('tab', { name: 'Deposit' }).click()
  await expect(page.getByText('Deposits are closed while a bonding round is open or due.')).toBeVisible()
  await expect(page.getByText('a bonding round is due and deposits are closed')).toBeVisible()
  await page.getByRole('button', { name: 'Open the bonding round' }).click()
  await expect(toast('Solvency check run')).toBeVisible()

  await page.locator('#bond').fill('1000')
  await expect(page.getByText('SYNTH vesting to you')).toBeVisible()
  await page.getByRole('button', { name: /^(Approve and )?bond USDC$/i }).click()
  await expect(toast('Bond bought')).toBeVisible()
  await expect(page.getByText('Bond #0')).toBeVisible()
  await shot('connected-vault-bonding')

  await warp(48n * 3_600n)
  await go('/vault')
  await page.getByRole('button', { name: /^Claim / }).click()
  await expect(toast('SYNTH claimed')).toBeVisible()
})
