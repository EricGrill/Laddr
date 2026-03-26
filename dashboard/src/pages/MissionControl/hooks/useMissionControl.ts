import { useEffect } from "react";
import { useTransportStore } from "../stores/transportStore";

export function useMissionControl() {
  const connect = useTransportStore((s) => s.connect);
  const disconnect = useTransportStore((s) => s.disconnect);
  const isConnected = useTransportStore((s) => s.isConnected);
  const error = useTransportStore((s) => s.error);

  useEffect(() => {
    connect();
    return () => disconnect();
  }, [connect, disconnect]);

  return { isConnected, error };
}
