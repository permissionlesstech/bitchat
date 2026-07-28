import { useEffect, useState } from "react";

const API_BASE_URL = import.meta.env.VITE_API_BASE_URL || "";

export default function Dashboard() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  useEffect(() => {
    const controller = new AbortController();

    async function fetchDashboardData() {
      try {
        setLoading(true);
        setError(null);

        const response = await fetch(`${API_BASE_URL}/dashboard/summary`, {
          signal: controller.signal,
        });

        if (!response.ok) {
          throw new Error(`HTTP error! status: ${response.status}`);
        }

        const result = await response.json();
        setData(result);
      } catch (err) {
        if (err.name !== "AbortError") {
          setError(err.message);
        }
      } finally {
        setLoading(false);
      }
    }

    fetchDashboardData();

    return () => controller.abort();
  }, []);

  if (loading) return <div>Loading...</div>;
  if (error) return <div>Error: {error}</div>;

  return (
    <div>
      <h2>ESAA Dashboard</h2>
      <h3>LED Displays: {data?.ledDisplays ?? 0}</h3>
      <h3>CCTV Cameras: {data?.cameras ?? 0}</h3>
      <h3>Energy: {data?.energy ?? 0} GWh</h3>
    </div>
  );
}
