import { createContext, useCallback, useContext, useMemo, useRef, useState, type ReactNode } from 'react'

export type ToastTone = 'pending' | 'success' | 'error'

export interface Toast {
  id: number
  tone: ToastTone
  title: string
  body?: string
  href?: string
}

interface ToastApi {
  toasts: Toast[]
  push: (t: Omit<Toast, 'id'>) => number
  update: (id: number, t: Partial<Omit<Toast, 'id'>>) => void
  dismiss: (id: number) => void
}

const ToastContext = createContext<ToastApi | null>(null)

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([])
  const nextId = useRef(1)
  const timers = useRef(new Map<number, number>())

  const dismiss = useCallback((id: number) => {
    setToasts((all) => all.filter((t) => t.id !== id))
    const timer = timers.current.get(id)
    if (timer) window.clearTimeout(timer)
    timers.current.delete(id)
  }, [])

  const schedule = useCallback(
    (id: number, tone: ToastTone) => {
      const old = timers.current.get(id)
      if (old) window.clearTimeout(old)
      if (tone === 'pending') return
      timers.current.set(id, window.setTimeout(() => dismiss(id), tone === 'error' ? 12_000 : 6_000))
    },
    [dismiss],
  )

  const push = useCallback(
    (t: Omit<Toast, 'id'>) => {
      const id = nextId.current++
      setToasts((all) => [...all.slice(-3), { ...t, id }])
      schedule(id, t.tone)
      return id
    },
    [schedule],
  )

  const update = useCallback(
    (id: number, t: Partial<Omit<Toast, 'id'>>) => {
      setToasts((all) => all.map((x) => (x.id === id ? { ...x, ...t } : x)))
      if (t.tone) schedule(id, t.tone)
    },
    [schedule],
  )

  const api = useMemo(() => ({ toasts, push, update, dismiss }), [toasts, push, update, dismiss])
  return <ToastContext.Provider value={api}>{children}</ToastContext.Provider>
}

export function useToasts() {
  const ctx = useContext(ToastContext)
  if (!ctx) throw new Error('useToasts outside ToastProvider')
  return ctx
}
