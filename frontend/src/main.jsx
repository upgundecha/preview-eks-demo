import React, { useEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';
import './style.css';

function App() {
  const [result, setResult] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function load() {
    const response = await fetch('/api/visits');
    if (!response.ok) throw new Error(`API returned ${response.status}`);
    setResult(await response.json());
  }

  useEffect(() => {
    load().catch((e) => setError(e.message));
  }, []);

  async function addVisit() {
    setBusy(true);
    setError('');
    try {
      const response = await fetch('/api/visits', { method: 'POST' });
      if (!response.ok) throw new Error(`API returned ${response.status}`);
      setResult(await response.json());
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <main>
      <p className="eyebrow">Feature branch environment</p>
      <h1>Hello again — second push 🔁</h1>
      <p>This page and its API run together at <strong>{window.location.host}</strong>.</p>
      <section aria-live="polite">
        <h2>{result ? `${result.visits} visits recorded` : 'Connecting to the API…'}</h2>
        <p>{result ? `Environment ${result.environment} · commit ${result.version.slice(0, 7)}` : 'Waiting for the Java service and database.'}</p>
        {error && <p className="error">{error}</p>}
        <button disabled={busy} onClick={addVisit}>Record a visit</button>
      </section>
      <p className="note">Refresh to check that the database survives a deployment update.</p>
    </main>
  );
}

createRoot(document.getElementById('root')).render(<App />);
