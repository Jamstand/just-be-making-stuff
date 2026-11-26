using Recshot.Native;
using Vortice.Direct2D1;
using Vortice.Direct3D;
using FeatureLevel = Vortice.Direct3D.FeatureLevel;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Windows.Graphics.DirectX.Direct3D11;

namespace Recshot.Capture;

/// <summary>
/// One D3D11 device shared by screen capture, Direct2D compositing and the GPU colour converter.
/// Every use of the immediate context goes through <see cref="Lock"/>.
/// </summary>
internal sealed class GpuDevice : IDisposable
{
    public ID3D11Device Device { get; }
    public ID3D11DeviceContext Context { get; }
    public ID2D1Factory1 D2DFactory { get; }
    public ID2D1Device D2DDevice { get; }
    public ID2D1DeviceContext D2D { get; }
    public IDirect3DDevice WinRTDevice { get; }
    public string AdapterName { get; }
    public bool HasVideoSupport { get; }
    public object Lock { get; } = new();

    public GpuDevice()
    {
        FeatureLevel[] levels = [FeatureLevel.Level_11_1, FeatureLevel.Level_11_0, FeatureLevel.Level_10_1];
        var flags = DeviceCreationFlags.BgraSupport | DeviceCreationFlags.VideoSupport;

        var result = D3D11.D3D11CreateDevice(IntPtr.Zero, DriverType.Hardware, flags, levels, out ID3D11Device? device, out ID3D11DeviceContext? context);
        HasVideoSupport = result.Success;
        if (result.Failure)
        {
            flags &= ~DeviceCreationFlags.VideoSupport;
            D3D11.D3D11CreateDevice(IntPtr.Zero, DriverType.Hardware, flags, levels, out device, out context).CheckError();
        }

        Device = device!;
        Context = context!;

        using (var mt = Device.QueryInterfaceOrNull<ID3D11Multithread>())
            mt?.SetMultithreadProtected(true);

        using (var dxgi = Device.QueryInterface<IDXGIDevice>())
        {
            using var adapter = dxgi.GetAdapter();
            AdapterName = adapter.Description.Description;

            D2DFactory = D2D1.D2D1CreateFactory<ID2D1Factory1>(FactoryType.MultiThreaded);
            D2DDevice = D2DFactory.CreateDevice(dxgi);
        }

        D2D = D2DDevice.CreateDeviceContext(DeviceContextOptions.None);
        D2D.UnitMode = UnitMode.Pixels;
        WinRTDevice = WinRTInterop.CreateWinRTDevice(Device);
        Log.Info($"GPU: {AdapterName} (video processor support: {HasVideoSupport})");
    }

    public void Dispose()
    {
        WinRTDevice.Dispose();
        D2D.Dispose();
        D2DDevice.Dispose();
        D2DFactory.Dispose();
        Context.ClearState();
        Context.Flush();
        Context.Dispose();
        Device.Dispose();
    }
}
