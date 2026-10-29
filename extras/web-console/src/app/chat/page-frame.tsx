// The same sandbox for conversation cards and the studio canvas.
export function PageFrame({ src, title, className, onLoad }: { src: string; title: string; className?: string; onLoad?: () => void }) {
  return <iframe onLoad={onLoad} src={src} title={title} referrerPolicy="no-referrer" loading="lazy"
    sandbox="allow-scripts allow-same-origin allow-popups allow-popups-to-escape-sandbox" className={className} />;
}
