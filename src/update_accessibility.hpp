#pragma once

#include <windows.h>
#include <commctrl.h>
#include <uiautomationclient.h>
#include <uiautomationcore.h>
#include <uiautomationcoreapi.h>
#include <oleauto.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <new>
#include <string>

namespace eye::update_accessibility {

enum class Kind { Button, Radio, CheckBox, Text, Progress, ProgressActivity };

inline HMODULE automationCoreModule() {
    static HMODULE module = LoadLibraryExW(L"uiautomationcore.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    return module;
}

template <typename Function>
inline Function resolveAutomationCoreFunction(const char* name) {
    const FARPROC address = GetProcAddress(automationCoreModule(), name);
    Function function{};
    static_assert(sizeof(function) == sizeof(address));
    std::memcpy(&function, &address, sizeof(function));
    return function;
}

inline decltype(&UiaReturnRawElementProvider) returnRawElementProvider() {
    return resolveAutomationCoreFunction<decltype(&UiaReturnRawElementProvider)>("UiaReturnRawElementProvider");
}
inline decltype(&UiaHostProviderFromHwnd) hostProviderFromHwnd() {
    return resolveAutomationCoreFunction<decltype(&UiaHostProviderFromHwnd)>("UiaHostProviderFromHwnd");
}

class Provider final : public IRawElementProviderSimple,
                       public IInvokeProvider,
                       public ISelectionItemProvider,
                       public IToggleProvider,
                       public IRangeValueProvider {
public:
    Provider(HWND window, Kind kind, bool stripMnemonic, const wchar_t* accessibleName)
        : window_(window), kind_(kind), stripMnemonic_(stripMnemonic), accessibleName_(accessibleName ? accessibleName : L"") {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** result) override {
        if (!result) return E_POINTER;
        *result = nullptr;
        if (IsEqualIID(iid, IID_IUnknown) || IsEqualIID(iid, IID_IRawElementProviderSimple)) {
            *result = static_cast<IRawElementProviderSimple*>(this);
        } else if (kind_ == Kind::Button && IsEqualIID(iid, IID_IInvokeProvider)) {
            *result = static_cast<IInvokeProvider*>(this);
        } else if (kind_ == Kind::Radio && IsEqualIID(iid, IID_ISelectionItemProvider)) {
            *result = static_cast<ISelectionItemProvider*>(this);
        } else if (kind_ == Kind::CheckBox && IsEqualIID(iid, IID_IToggleProvider)) {
            *result = static_cast<IToggleProvider*>(this);
        } else if (kind_ == Kind::Progress && IsEqualIID(iid, IID_IRangeValueProvider)) {
            *result = static_cast<IRangeValueProvider*>(this);
        } else {
            return E_NOINTERFACE;
        }
        AddRef();
        return S_OK;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
    ULONG STDMETHODCALLTYPE Release() override {
        const ULONG remaining = --references_;
        if (!remaining) delete this;
        return remaining;
    }

    HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions* result) override {
        if (!result) return E_POINTER;
        *result = static_cast<ProviderOptions>(ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading);
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID pattern, IUnknown** result) override {
        if (!result) return E_POINTER;
        *result = nullptr;
        if (kind_ == Kind::Button && pattern == UIA_InvokePatternId) {
            *result = static_cast<IInvokeProvider*>(this);
        } else if (kind_ == Kind::Radio && pattern == UIA_SelectionItemPatternId) {
            *result = static_cast<ISelectionItemProvider*>(this);
        } else if (kind_ == Kind::CheckBox && pattern == UIA_TogglePatternId) {
            *result = static_cast<IToggleProvider*>(this);
        } else if (kind_ == Kind::Progress && pattern == UIA_RangeValuePatternId) {
            *result = static_cast<IRangeValueProvider*>(this);
        } else {
            return S_OK;
        }
        AddRef();
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID property, VARIANT* value) override {
        if (!value) return E_POINTER;
        VariantInit(value);
        if (!IsWindow(window_)) return UIA_E_ELEMENTNOTAVAILABLE;
        if (property == UIA_ControlTypePropertyId) {
            value->vt = VT_I4;
            switch (kind_) {
                case Kind::Button: value->lVal = UIA_ButtonControlTypeId; break;
                case Kind::Radio: value->lVal = UIA_RadioButtonControlTypeId; break;
                case Kind::CheckBox: value->lVal = UIA_CheckBoxControlTypeId; break;
                case Kind::Text: value->lVal = UIA_TextControlTypeId; break;
                case Kind::Progress: value->lVal = UIA_ProgressBarControlTypeId; break;
                case Kind::ProgressActivity: value->lVal = UIA_ProgressBarControlTypeId; break;
            }
        } else if (property == UIA_NamePropertyId) {
            std::wstring name = accessibleName_;
            if (name.empty()) {
                const int count = GetWindowTextLengthW(window_);
                name.resize(std::size_t(std::max(0, count)) + 1, L'\0');
                if (count) GetWindowTextW(window_, name.data(), count + 1);
                name.resize(std::size_t(std::max(0, count)));
            }
            if (stripMnemonic_) name = plainLabel(name);
            value->vt = VT_BSTR;
            value->bstrVal = SysAllocStringLen(name.data(), UINT(name.size()));
            if (!value->bstrVal && !name.empty()) return E_OUTOFMEMORY;
        } else if (property == UIA_AutomationIdPropertyId) {
            const int id = GetDlgCtrlID(window_);
            const std::wstring automationId = id > 0 ? std::to_wstring(id) : std::wstring{};
            value->vt = VT_BSTR;
            value->bstrVal = SysAllocStringLen(automationId.data(), UINT(automationId.size()));
            if (!value->bstrVal && !automationId.empty()) return E_OUTOFMEMORY;
        } else if (property == UIA_IsKeyboardFocusablePropertyId) {
            value->vt = VT_BOOL;
            value->boolVal = (GetWindowLongPtrW(window_, GWL_STYLE) & WS_TABSTOP) && IsWindowEnabled(window_)
                                 ? VARIANT_TRUE : VARIANT_FALSE;
        } else if (property == UIA_HasKeyboardFocusPropertyId) {
            value->vt = VT_BOOL;
            value->boolVal = GetFocus() == window_ ? VARIANT_TRUE : VARIANT_FALSE;
        } else if (property == UIA_IsEnabledPropertyId) {
            value->vt = VT_BOOL;
            value->boolVal = IsWindowEnabled(window_) ? VARIANT_TRUE : VARIANT_FALSE;
        } else if (property == UIA_IsControlElementPropertyId || property == UIA_IsContentElementPropertyId) {
            value->vt = VT_BOOL;
            value->boolVal = VARIANT_TRUE;
        } else if (kind_ == Kind::Progress && property == UIA_RangeValueValuePropertyId) {
            value->vt = VT_R8;
            value->dblVal = double(SendMessageW(window_, PBM_GETPOS, 0, 0));
        } else if (kind_ == Kind::Progress && property == UIA_RangeValueIsReadOnlyPropertyId) {
            value->vt = VT_BOOL;
            value->boolVal = VARIANT_TRUE;
        } else if (kind_ == Kind::Progress && property == UIA_RangeValueMinimumPropertyId) {
            value->vt = VT_R8;
            value->dblVal = 0.0;
        } else if (kind_ == Kind::Progress && property == UIA_RangeValueMaximumPropertyId) {
            value->vt = VT_R8;
            value->dblVal = 1000.0;
        }
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(IRawElementProviderSimple** result) override {
        if (!result) return E_POINTER;
        *result = nullptr;
        if (!IsWindow(window_)) return UIA_E_ELEMENTNOTAVAILABLE;
        const auto hostProvider = hostProviderFromHwnd();
        return hostProvider ? hostProvider(window_, result) : UIA_E_NOTSUPPORTED;
    }

    HRESULT STDMETHODCALLTYPE Invoke() override { return click(); }

    HRESULT STDMETHODCALLTYPE Select() override {
        if (!IsWindow(window_)) return UIA_E_ELEMENTNOTAVAILABLE;
        if (SendMessageW(window_, BM_GETCHECK, 0, 0) != BST_CHECKED) return click();
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE AddToSelection() override { return Select(); }
    HRESULT STDMETHODCALLTYPE RemoveFromSelection() override { return UIA_E_INVALIDOPERATION; }
    HRESULT STDMETHODCALLTYPE get_IsSelected(BOOL* result) override {
        if (!result) return E_POINTER;
        if (!IsWindow(window_)) return UIA_E_ELEMENTNOTAVAILABLE;
        *result = SendMessageW(window_, BM_GETCHECK, 0, 0) == BST_CHECKED;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_SelectionContainer(IRawElementProviderSimple** result) override {
        if (!result) return E_POINTER;
        *result = nullptr;
        if (!IsWindow(window_)) return UIA_E_ELEMENTNOTAVAILABLE;
        const auto hostProvider = hostProviderFromHwnd();
        return hostProvider ? hostProvider(GetParent(window_), result) : UIA_E_NOTSUPPORTED;
    }

    HRESULT STDMETHODCALLTYPE Toggle() override { return click(); }
    HRESULT STDMETHODCALLTYPE get_ToggleState(ToggleState* result) override {
        if (!result) return E_POINTER;
        if (!IsWindow(window_)) return UIA_E_ELEMENTNOTAVAILABLE;
        const LRESULT state = SendMessageW(window_, BM_GETCHECK, 0, 0);
        *result = state == BST_CHECKED ? ToggleState_On
                 : state == BST_INDETERMINATE ? ToggleState_Indeterminate : ToggleState_Off;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE SetValue(double) override { return UIA_E_NOTSUPPORTED; }
    HRESULT STDMETHODCALLTYPE get_Value(double* result) override {
        if (!result) return E_POINTER;
        if (!IsWindow(window_)) return UIA_E_ELEMENTNOTAVAILABLE;
        *result = double(SendMessageW(window_, PBM_GETPOS, 0, 0));
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_IsReadOnly(BOOL* result) override {
        if (!result) return E_POINTER;
        *result = TRUE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_Maximum(double* result) override {
        if (!result) return E_POINTER;
        *result = 1000.0;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_Minimum(double* result) override {
        if (!result) return E_POINTER;
        *result = 0.0;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_LargeChange(double* result) override {
        if (!result) return E_POINTER;
        *result = 0.0;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_SmallChange(double* result) override {
        if (!result) return E_POINTER;
        *result = 0.0;
        return S_OK;
    }

private:
    static std::wstring plainLabel(const std::wstring& label) {
        std::wstring result;
        result.reserve(label.size());
        for (std::size_t i = 0; i < label.size(); ++i) {
            if (label[i] == L'&') {
                if (i + 1 < label.size() && label[i + 1] == L'&') {
                    result.push_back(L'&');
                    ++i;
                }
            } else {
                result.push_back(label[i]);
            }
        }
        return result;
    }

    HRESULT click() {
        if (!IsWindow(window_)) return UIA_E_ELEMENTNOTAVAILABLE;
        if (!IsWindowEnabled(window_)) return UIA_E_ELEMENTNOTENABLED;
        SendMessageW(window_, BM_CLICK, 0, 0);
        return S_OK;
    }

    std::atomic<ULONG> references_{1};
    HWND window_{};
    Kind kind_{};
    bool stripMnemonic_{};
    std::wstring accessibleName_;
};

inline LRESULT CALLBACK controlProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam,
                                    UINT_PTR subclassId, DWORD_PTR reference) {
    auto* provider = reinterpret_cast<Provider*>(reference);
    if (message == WM_GETOBJECT && static_cast<LONG>(lParam) == UiaRootObjectId && provider) {
        const auto returnProvider = returnRawElementProvider();
        if (returnProvider) return returnProvider(window, wParam, lParam, provider);
    }
    if (message == WM_NCDESTROY) {
        RemoveWindowSubclass(window, controlProc, subclassId);
        if (provider) provider->Release();
    }
    return DefSubclassProc(window, message, wParam, lParam);
}

inline bool attach(HWND window, Kind kind, bool stripMnemonic = false, const wchar_t* accessibleName = nullptr) {
    Provider* provider = nullptr;
    try { provider = new (std::nothrow) Provider(window, kind, stripMnemonic, accessibleName); }
    catch (...) { return false; }
    if (!provider) return false;
    if (!SetWindowSubclass(window, controlProc, 1, reinterpret_cast<DWORD_PTR>(provider))) {
        provider->Release();
        return false;
    }
    return true;
}

inline bool attachButton(HWND window, const wchar_t* accessibleName = nullptr) {
    const DWORD type = DWORD(GetWindowLongPtrW(window, GWL_STYLE)) & BS_TYPEMASK;
    switch (type) {
        case BS_RADIOBUTTON:
        case BS_AUTORADIOBUTTON: return attach(window, Kind::Radio, true, accessibleName);
        case BS_CHECKBOX:
        case BS_AUTOCHECKBOX:
        case BS_3STATE:
        case BS_AUTO3STATE: return attach(window, Kind::CheckBox, true, accessibleName);
        case BS_PUSHBUTTON:
        case BS_DEFPUSHBUTTON: return attach(window, Kind::Button, true, accessibleName);
        default: return false;
    }
}

inline bool attachActivityProgress(HWND window, const wchar_t* accessibleName) {
    return attach(window, Kind::ProgressActivity, false, accessibleName);
}

} // namespace eye::update_accessibility
