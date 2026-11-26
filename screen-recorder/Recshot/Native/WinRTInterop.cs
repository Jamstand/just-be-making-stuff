using System.Runtime.InteropServices;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX.Direct3D11;
using WinRT;

namespace Recshot.Native;

/// <summary>
/// The few COM interop calls needed to bridge Windows.Graphics.Capture (WinRT) and raw Direct3D 11.
/// These are called through the vtable directly so they don't depend on built-in COM marshalling.
/// </summary>
internal static unsafe class WinRTInterop
{
    private static readonly Guid IID_IGraphicsCaptureItemInterop = new("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356");
    private static readonly Guid IID_IGraphicsCaptureItem = new("79C3F95B-31F7-4EC2-A464-632EF5D30760");
    private static readonly Guid IID_IDirect3DDxgiInterfaceAccess = new("A9B3D012-3DF2-4EE3-B8D1-8695F457D3C1");
    private static readonly Guid IID_ID3D11Texture2D = new("6F15AAF2-D208-4E89-9AB4-489535D34F9C");

    [DllImport("d3d11.dll", ExactSpelling = true)]
    private static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);

    public static GraphicsCaptureItem CreateItemForWindow(IntPtr hwnd) => CreateItem(hwnd, 3);
    public static GraphicsCaptureItem CreateItemForMonitor(IntPtr hmonitor) => CreateItem(hmonitor, 4);

    private static GraphicsCaptureItem CreateItem(IntPtr handle, int vtableSlot)
    {
        // IGraphicsCaptureItemInterop : IUnknown { CreateForWindow (slot 3); CreateForMonitor (slot 4); }
        IObjectReference factory = ActivationFactory.Get("Windows.Graphics.Capture.GraphicsCaptureItem");
        Guid interopIid = IID_IGraphicsCaptureItemInterop;
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(factory.ThisPtr, in interopIid, out IntPtr interop));
        try
        {
            IntPtr* vtbl = *(IntPtr**)interop;
            var create = (delegate* unmanaged[Stdcall]<IntPtr, IntPtr, Guid*, IntPtr*, int>)vtbl[vtableSlot];
            Guid itemIid = IID_IGraphicsCaptureItem;
            IntPtr itemPtr;
            Marshal.ThrowExceptionForHR(create(interop, handle, &itemIid, &itemPtr));
            try
            {
                return GraphicsCaptureItem.FromAbi(itemPtr);
            }
            finally
            {
                Marshal.Release(itemPtr);
            }
        }
        finally
        {
            Marshal.Release(interop);
        }
    }

    public static IDirect3DDevice CreateWinRTDevice(ID3D11Device device)
    {
        using IDXGIDevice dxgi = device.QueryInterface<IDXGIDevice>();
        Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgi.NativePointer, out IntPtr inspectable));
        try
        {
            return MarshalInterface<IDirect3DDevice>.FromAbi(inspectable);
        }
        finally
        {
            Marshal.Release(inspectable);
        }
    }

    /// <summary>Returns the ID3D11Texture2D behind a WinRT surface. Caller disposes it.</summary>
    public static ID3D11Texture2D GetTexture(IDirect3DSurface surface)
    {
        IntPtr unknown = MarshalInspectable<IDirect3DSurface>.FromManaged(surface);
        try
        {
            Guid accessIid = IID_IDirect3DDxgiInterfaceAccess;
            Marshal.ThrowExceptionForHR(Marshal.QueryInterface(unknown, in accessIid, out IntPtr access));
            try
            {
                // IDirect3DDxgiInterfaceAccess : IUnknown { GetInterface (slot 3) }
                IntPtr* vtbl = *(IntPtr**)access;
                var getInterface = (delegate* unmanaged[Stdcall]<IntPtr, Guid*, IntPtr*, int>)vtbl[3];
                Guid texIid = IID_ID3D11Texture2D;
                IntPtr texture;
                Marshal.ThrowExceptionForHR(getInterface(access, &texIid, &texture));
                return new ID3D11Texture2D(texture);
            }
            finally
            {
                Marshal.Release(access);
            }
        }
        finally
        {
            Marshal.Release(unknown);
        }
    }
}
