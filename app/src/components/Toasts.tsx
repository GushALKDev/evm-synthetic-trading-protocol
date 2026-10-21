import { useToasts } from '../hooks/useToasts'
import { CloseIcon, ToastIcon } from './icons'

export function Toasts() {
  const { toasts, dismiss } = useToasts()
  return (
    <div className="toasts" role="status" aria-live="polite">
      {toasts.map((t) => (
        <div className="toast" key={t.id} data-tone={t.tone}>
          <ToastIcon tone={t.tone} />
          <div>
            <div className="toast-title">{t.title}</div>
            {t.body ? <div className="toast-body">{t.body}</div> : null}
            {t.href ? (
              <a className="toast-body" href={t.href} target="_blank" rel="noreferrer">
                View on the explorer
              </a>
            ) : null}
          </div>
          <button className="btn btn-quiet" style={{ minHeight: 24, padding: 0 }} onClick={() => dismiss(t.id)} aria-label="Dismiss">
            <CloseIcon />
          </button>
        </div>
      ))}
    </div>
  )
}
