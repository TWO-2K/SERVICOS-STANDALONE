import React from 'react';
import ReactDOM from 'react-dom/client';

import App from '@/App.jsx';
import '@/index.css';
import { APP_NAME } from '@/lib/branding';

document.title = `${APP_NAME} · Plataforma`;

ReactDOM.createRoot(document.getElementById('root')).render(<App />);
