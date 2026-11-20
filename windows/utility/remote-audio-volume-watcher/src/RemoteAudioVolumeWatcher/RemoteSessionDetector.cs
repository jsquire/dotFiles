using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Squire.RemoteAudioVolumeWatcher;

/// <summary>
/// Identifies the client protocol used by the current Windows session.
/// </summary>
internal static class RemoteSessionDetector
{
    /// <summary>
    /// Determines whether the current session uses the Remote Desktop protocol.
    /// </summary>
    ///
    /// <returns><see langword="true"/> for an RDP session.</returns>
    ///
    public static bool IsRemoteDesktopSession()
    {
        if (!Native.WtsQuerySessionInformation(
            nint.Zero,
            Native.WtsCurrentSession,
            Native.WtsClientProtocolType,
            out var buffer,
            out var byteCount))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to query the current session protocol.");
        }

        try
        {
            return (byteCount >= sizeof(short)) && (Marshal.ReadInt16(buffer) == Native.WtsProtocolRdp);
        }
        finally
        {
            Native.WtsFreeMemory(buffer);
        }
    }
}