import { cva } from 'class-variance-authority';
import { Banknote } from 'lucide-react';

import { CarSilhouette } from './car-icon';
import { cn } from './lib/utils';

const spinnerVariants = cva('animate-spin rounded-full border-current/25 border-t-current', {
  variants: {
    size: {
      sm: 'h-4 w-4 border-2',
      default: 'h-5 w-5 border-2',
      lg: 'h-8 w-8 border-4',
    },
  },
  defaultVariants: {
    size: 'default',
  },
});

function Spinner({ className, size, ...props }) {
  return (
    <div role="status" aria-label="Carregando" className={cn(spinnerVariants({ size }), className)} {...props} />
  );
}

function PageLoader({ className = '', spinnerClassName = '', size = 'default', label = '', ...props }) {
  return (
    <main
      className={cn('flex min-h-screen items-center justify-center bg-background', className)}
      {...props}
    >
      <div className="flex items-center gap-3 rounded-2xl bg-card px-6 py-4 shadow-sm">
        <Spinner size={size} className={cn('text-primary', spinnerClassName)} />
        {label ? <span className="text-sm text-muted-foreground">{label}</span> : null}
      </div>
    </main>
  );
}

const BRAND_ASSEMBLE_CSS = `
@keyframes brand-fade {
  0%, 100% { opacity: 0.3; }
  50% { opacity: 0.9; }
}
`;

function BrandLoader({ className = '', ...props }) {
  return (
    <main
      role="status"
      aria-label="Carregando"
      className={cn('flex min-h-screen flex-col items-center justify-center gap-6 bg-background', className)}
      {...props}
    >
      <style>{BRAND_ASSEMBLE_CSS}</style>
      <div className="flex h-[120px] w-[120px] items-center justify-center">
        <Spinner size="lg" className="h-14 w-14 border-[5px] text-primary" />
      </div>
      <span
        className="text-sm uppercase tracking-[4px] text-primary"
        style={{ animation: 'brand-fade 1.4s ease-in-out infinite' }}
      >
        Carregando
      </span>
    </main>
  );
}

const CAR_CSS = `
@keyframes car-bounce {
  0%, 100% { transform: translateY(0); }
  50% { transform: translateY(-5px); }
}
@keyframes car-road-move {
  0% { background-position-x: 0; }
  100% { background-position-x: -32px; }
}
@keyframes brand-fade {
  0%, 100% { opacity: 0.3; }
  50% { opacity: 0.9; }
}
`;

function CarLoaderIcon({ className = '', size = 'default' }) {
  const dims =
    size === 'sm'
      ? { box: 'h-[68px] w-[120px]', car: 'h-[50px] w-[112px]', road: 'w-[130px]' }
      : { box: 'h-[92px] w-[160px]', car: 'h-[68px] w-[150px]', road: 'w-[172px]' };

  return (
    <div className={cn('flex items-end justify-center', dims.box, className)}>
      <style>{CAR_CSS}</style>
      <div className="flex flex-col items-center">
        <CarSilhouette className={dims.car} style={{ animation: 'car-bounce 0.6s ease-in-out infinite' }} />
        <div
          className={cn('mt-2 h-[2px] text-muted-foreground/40', dims.road)}
          style={{
            backgroundImage: 'repeating-linear-gradient(to right, currentColor 0, currentColor 12px, transparent 12px, transparent 20px)',
            animation: 'car-road-move 0.5s linear infinite',
          }}
        />
      </div>
    </div>
  );
}

function CarLoader({ className = '', inline = false, label = 'Carregando', ...props }) {
  if (inline) {
    return (
      <div
        role="status"
        aria-label={label}
        className={cn('flex flex-col items-center justify-center gap-2 py-12', className)}
        {...props}
      >
        <CarLoaderIcon size="sm" />
        {label ? (
          <span
            className="text-xs uppercase tracking-[3px] text-primary"
            style={{ animation: 'brand-fade 1.4s ease-in-out infinite' }}
          >
            {label}
          </span>
        ) : null}
      </div>
    );
  }

  return (
    <main
      role="status"
      aria-label={label}
      className={cn('flex min-h-screen flex-col items-center justify-center gap-6 bg-background', className)}
      {...props}
    >
      <CarLoaderIcon />
      <span
        className="text-sm uppercase tracking-[4px] text-primary"
        style={{ animation: 'brand-fade 1.4s ease-in-out infinite' }}
      >
        {label}
      </span>
    </main>
  );
}

const MONEY_CSS = `
@keyframes money-bounce {
  0%, 100% { transform: translateY(0) rotate(-4deg); }
  50% { transform: translateY(-8px) rotate(4deg); }
}
@keyframes brand-fade {
  0%, 100% { opacity: 0.3; }
  50% { opacity: 0.9; }
}
`;

function MoneyLoaderIcon({ className = '', size = 'default' }) {
  const dims =
    size === 'sm' ? { box: 'h-[68px] w-[68px]', icon: 'h-8 w-8' } : { box: 'h-[92px] w-[92px]', icon: 'h-11 w-11' };

  return (
    <div className={cn('flex items-center justify-center', dims.box, className)}>
      <style>{MONEY_CSS}</style>
      <Banknote
        className={cn(dims.icon, 'text-primary')}
        style={{ animation: 'money-bounce 1.2s ease-in-out infinite' }}
      />
    </div>
  );
}

function MoneyLoader({ className = '', inline = false, label = 'Carregando', ...props }) {
  if (inline) {
    return (
      <div
        role="status"
        aria-label={label}
        className={cn('flex flex-col items-center justify-center gap-2 py-12', className)}
        {...props}
      >
        <MoneyLoaderIcon size="sm" />
        {label ? (
          <span
            className="text-xs uppercase tracking-[3px] text-primary"
            style={{ animation: 'brand-fade 1.4s ease-in-out infinite' }}
          >
            {label}
          </span>
        ) : null}
      </div>
    );
  }

  return (
    <main
      role="status"
      aria-label={label}
      className={cn('flex min-h-screen flex-col items-center justify-center gap-6 bg-background', className)}
      {...props}
    >
      <MoneyLoaderIcon />
      <span
        className="text-sm uppercase tracking-[4px] text-primary"
        style={{ animation: 'brand-fade 1.4s ease-in-out infinite' }}
      >
        {label}
      </span>
    </main>
  );
}

export { Spinner, spinnerVariants, PageLoader, BrandLoader, CarLoader, MoneyLoader };
