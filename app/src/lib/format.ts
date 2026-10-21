const groupInt = (s: string) => s.replace(/\B(?=(\d{3})+(?!\d))/g, ',')

/**
 * Formats a fixed-point bigint. Truncates toward zero, so a balance is never shown higher than it is.
 * `shown` is the number of decimals displayed; trailing zeros are kept for column alignment.
 */
export function formatFixed(value: bigint, decimals: number, shown: number): string {
  const negative = value < 0n
  const abs = negative ? -value : value
  const scale = 10n ** BigInt(decimals)
  const int = abs / scale
  let out = groupInt(int.toString())
  if (shown > 0) {
    const frac = (abs % scale).toString().padStart(decimals, '0').slice(0, shown).padEnd(shown, '0')
    out += `.${frac}`
  }
  return negative ? `-${out}` : out
}

/** Signed amount with an explicit sign, for PnL and funding: +12.30, -4.00 */
export function formatSigned(value: bigint, decimals: number, shown: number): string {
  const s = formatFixed(value, decimals, shown)
  return value > 0n ? `+${s}` : s
}

/** Compact form for large totals: 1.25M, 340.5K. */
export function formatCompact(value: bigint, decimals: number): string {
  const n = Number(value) / 10 ** decimals
  const abs = Math.abs(n)
  if (abs >= 1e9) return `${(n / 1e9).toFixed(2)}B`
  if (abs >= 1e6) return `${(n / 1e6).toFixed(2)}M`
  if (abs >= 1e4) return `${(n / 1e3).toFixed(1)}K`
  return n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
}

/** Decimals that keep about five significant digits for a price: BTC 2, LINK 3 or 4 */
export function priceDecimals(price18: bigint): number {
  const whole = price18 / 10n ** 18n
  if (whole >= 1_000n) return 2
  if (whole >= 10n) return 3
  return 4
}

/** USD price at 18 decimals */
export function formatPrice(price18: bigint): string {
  return `$${formatFixed(price18, 18, priceDecimals(price18))}`
}

/** USD value at 18 decimals */
export function formatUsd(value18: bigint, shown = 2): string {
  const negative = value18 < 0n
  const s = formatFixed(negative ? -value18 : value18, 18, shown)
  return `${negative ? '-' : ''}$${s}`
}

/** Fraction at 1e18 scale as a percentage. */
export function formatPct(value18: bigint, shown = 2): string {
  return `${formatFixed(value18 * 100n, 18, shown)}%`
}

/** Basis points as a percentage: 8000 -> 80%, 5 -> 0.05%. */
export function formatBps(bps: bigint): string {
  const whole = bps / 100n
  const frac = bps % 100n
  return frac === 0n ? `${whole}%` : `${whole}.${frac.toString().padStart(2, '0').replace(/0$/, '')}%`
}

/** An hourly funding rate (WAD per unit of notional) as a percentage per hour, with an explicit sign */
export function formatRatePerHour(rate: bigint): string {
  const pct = formatFixed(rate * 100n, 18, 4)
  return `${rate > 0n ? '+' : ''}${pct}% per hour`
}

export function shortAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`
}

/** Parses a user-typed decimal amount into base units; null if it is not a valid number. */
export function parseAmount(input: string, decimals: number): bigint | null {
  const s = input.trim().replace(/,/g, '')
  if (!/^\d*\.?\d*$/.test(s) || s === '' || s === '.') return null
  const [int, frac = ''] = s.split('.')
  if (frac.length > decimals) return null
  return BigInt(int || '0') * 10n ** BigInt(decimals) + BigInt(frac.padEnd(decimals, '0') || '0')
}

/** Inverse of parseAmount for Max buttons: no grouping, trailing zeros trimmed. */
export function toInput(value: bigint, decimals: number): string {
  const scale = 10n ** BigInt(decimals)
  const frac = (value % scale).toString().padStart(decimals, '0').replace(/0+$/, '')
  return frac ? `${value / scale}.${frac}` : `${value / scale}`
}

/** A duration in its two largest units, each truncated: 59.9 minutes is 59 min, never 60 */
export function relativeTime(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds))
  if (s < 60) return `${s} s`
  if (s < 3600) return `${Math.floor(s / 60)} min`
  if (s < 86_400) return `${Math.floor(s / 3600)} h ${Math.floor((s % 3600) / 60)} min`
  const days = Math.floor(s / 86_400)
  const hours = Math.floor((s % 86_400) / 3600)
  return hours > 0 ? `${days} d ${hours} h` : `${days} d`
}
