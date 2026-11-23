#include "Studio.h"
#include <winrt/Microsoft.UI.Xaml.Markup.h>
#include <winrt/Microsoft.UI.Xaml.XamlTypeInfo.h>
#include <shellapi.h>
#include <fstream>
using namespace winrt;
namespace X = winrt::Microsoft::UI::Xaml;
namespace
{
std::vector<std::wstring> args;
bool testing()
{
    return args.size() == 4 && args[1] == L"--self-test";
}
int result = 0;
void fail(std::wstring_view msg)
{
    result = 1;
    if (testing())
        std::ofstream(std::filesystem::path(args[3]) / L"failure.txt") << to_string(msg);
    else
        MessageBoxW(nullptr, std::wstring(msg).c_str(), L"Forma", MB_ICONERROR);
}
struct FormaApp : X::ApplicationT<FormaApp, X::Markup::IXamlMetadataProvider>
{
    X::XamlTypeInfo::XamlControlsXamlMetaDataProvider metadata;
    X::Markup::IXamlType GetXamlType(winrt::Windows::UI::Xaml::Interop::TypeName const &t)
    {
        return metadata.GetXamlType(t);
    }
    X::Markup::IXamlType GetXamlType(hstring const &t)
    {
        return metadata.GetXamlType(t);
    }
    auto GetXmlnsDefinitions()
    {
        return metadata.GetXmlnsDefinitions();
    }
    winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer testTimer{nullptr};
    X::Window window{nullptr};
    std::unique_ptr<forma::Studio> studio;
    void OnLaunched(X::LaunchActivatedEventArgs const &)
    {
        try
        {
            Resources().MergedDictionaries().Append(X::Controls::XamlControlsResources());
            window = X::Window();
            window.AppWindow().Resize({1240, 800});
            studio = std::make_unique<forma::Studio>(window);
            studio->build();
            if (testing())
            {
                testTimer = window.DispatcherQueue().CreateTimer();
                testTimer.Interval(std::chrono::milliseconds(100));
                testTimer.Tick([this, attempt = 0](auto const &timer, auto &&) mutable {
                    studio->root.UpdateLayout();
                    if (studio->canvas.ActualWidth() <= 100 && ++attempt < 35)
                        return;
                    timer.Stop();
                    try
                    {
                        studio->selfTest(args[2], args[3]);
                    }
                    catch (hresult_error const &e)
                    {
                        fail(e.message());
                    }
                    catch (std::exception const &e)
                    {
                        fail(to_hstring(e.what()));
                    }
                    studio->editor.markSaved();
                    window.Close();
                });
                testTimer.Start();
            }
            else if (args.size() == 2)
                studio->guarded([&] { studio->openPath(args[1]); });
        }
        catch (hresult_error const &e)
        {
            fail(e.message());
            Exit();
        }
        catch (std::exception const &e)
        {
            fail(to_hstring(e.what()));
            Exit();
        }
    }
};
} // namespace
int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int)
{
    int n;
    auto items = CommandLineToArgvW(GetCommandLineW(), &n);
    if (items)
    {
        args.assign(items, items + n);
        LocalFree(items);
    }
    try
    {
        init_apartment(apartment_type::single_threaded);
        X::Application::Start([](auto &&) { make<FormaApp>(); });
    }
    catch (hresult_error const &e)
    {
        fail(e.message());
    }
    catch (std::exception const &e)
    {
        fail(to_hstring(e.what()));
    }
    return result;
}
