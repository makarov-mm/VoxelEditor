#pragma once
#include "Viewport.h"
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.System.h>
#include <winrt/Windows.UI.Text.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Input.h>
#include <winrt/Microsoft.UI.Windowing.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <functional>
namespace forma
{
namespace X = winrt::Microsoft::UI::Xaml;
namespace C = X::Controls;
namespace Input = X::Input;
using winrt::hstring;
Scene lighthouse();
struct Studio
{
    X::Window window{nullptr};
    HWND hwnd{};
    C::Grid root;
    C::SwapChainPanel canvas;
    C::StackPanel rail, inspector;
    C::TextBlock title, status;
    C::ScrollViewer inspectorScroll;
    Editor editor;
    Viewport viewport;
    Cells visible, preview, fragment, strokeScene;
    Cell fragmentBase{}, anchor{}, normal{}, moveDelta{};
    std::optional<Cell> dragAnchor;
    bool validPaste{}, sliced{}, ready{}, syncing{}, fitted{}, addSelection{}, exporting{};
    int sliceLevel{}, dragDepth{};
    float startX{}, startY{}, lastX{}, lastY{};
    enum class Drag
    {
        None,
        Brush,
        Orbit,
        Pan,
        Shape,
        Extrude,
        Select,
        Move
    } drag{};
    std::filesystem::path file;
    std::array<C::Button, 10> tools{nullptr, nullptr, nullptr, nullptr, nullptr,
                                    nullptr, nullptr, nullptr, nullptr, nullptr};
    C::Button undoButton{nullptr}, redoButton{nullptr};
    C::Border selectionBox;
    Studio(X::Window const &);
    void build();
    void sidebar();
    void refresh(bool side = false);
    void resize();
    void redraw();
    void message(std::wstring_view);
    void guarded(std::function<void()> const &);
    void action(std::function<void()>);
    void tool(Tool);
    void updateStatus();
    void orient(int);
    void project(Scene s, std::filesystem::path path = {});
    void open();
    void openPath(std::filesystem::path const &);
    bool save(bool as = false);
    bool mayClose();
    void exportFile(int);
    void copy(bool cut);
    void paste();
    void updatePaste();
    void place();
    void clearInteraction(bool rollback);
    void pointerDown(Input::PointerRoutedEventArgs const &);
    void pointerMove(Input::PointerRoutedEventArgs const &);
    void pointerUp(Input::PointerRoutedEventArgs const &);
    void hover(Pick const &);
    void key(Input::KeyRoutedEventArgs const &);
    void setSlice(bool, int);
    void selfTest(std::filesystem::path const &, std::filesystem::path const &);
};
} // namespace forma
