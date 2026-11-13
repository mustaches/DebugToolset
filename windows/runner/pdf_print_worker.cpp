#include <fpdfview.h>
#include <objbase.h>
#include <windows.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cwctype>
#include <fstream>
#include <string>
#include <vector>

namespace {

void LogPrintStage(const char* stage) { OutputDebugStringA(stage); }

int Fail(const char* message) {
  fprintf(stderr, "%s\n", message);
  return 1;
}

int FailWin32(const char* message) {
  const auto error = GetLastError();
  if (error == 0 || error == ERROR_CANCELLED ||
      error == ERROR_PRINT_CANCELLED) {
    return 2;
  }
  fprintf(stderr, "%s (Windows error %lu).\n", message, error);
  return 1;
}

std::wstring PrinterDeviceName(const PRINTDLG& dialog) {
  if (dialog.hDevNames == nullptr) return L"";
  const auto* names = static_cast<DEVNAMES*>(GlobalLock(dialog.hDevNames));
  if (names == nullptr) return L"";
  const auto device = reinterpret_cast<const wchar_t*>(names) + names->wDeviceOffset;
  std::wstring result(device);
  GlobalUnlock(dialog.hDevNames);
  return result;
}

bool IsPdfPrinter(const PRINTDLG& dialog) {
  auto device = PrinterDeviceName(dialog);
  std::transform(device.begin(), device.end(), device.begin(),
                 [](wchar_t c) { return std::towlower(c); });
  return device.find(L"pdf") != std::wstring::npos;
}

int SavePdfDirectly(const std::vector<uint8_t>& document,
                    const std::wstring& suggested_name) {
  FPDF_LIBRARY_CONFIG config{};
  config.version = 2;
  FPDF_InitLibraryWithConfig(&config);
  auto pdf = FPDF_LoadMemDocument64(document.data(), document.size(), nullptr);
  if (pdf == nullptr) {
    FPDF_DestroyLibrary();
    return Fail("Could not open the generated PDF.");
  }
  const auto page_count = FPDF_GetPageCount(pdf);
  FPDF_CloseDocument(pdf);
  FPDF_DestroyLibrary();

  wchar_t file_path[MAX_PATH];
  wcsncpy_s(file_path, suggested_name.c_str(), _TRUNCATE);
  OPENFILENAME save_dialog{};
  save_dialog.lStructSize = sizeof(save_dialog);
  save_dialog.lpstrFile = file_path;
  save_dialog.nMaxFile = MAX_PATH;
  save_dialog.lpstrFilter = L"PDF Files (*.pdf)\0*.pdf\0\0";
  save_dialog.lpstrDefExt = L"pdf";
  save_dialog.lpstrTitle = L"Save PDF";
  save_dialog.Flags = OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST;
  if (!GetSaveFileName(&save_dialog)) {
    return CommDlgExtendedError() == 0 ? 2 : 1;
  }

  HANDLE file = INVALID_HANDLE_VALUE;
  while (file == INVALID_HANDLE_VALUE) {
    file = CreateFileW(file_path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                       FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file != INVALID_HANDLE_VALUE) break;
    if (GetLastError() != ERROR_SHARING_VIOLATION) {
      return FailWin32("Could not create the output PDF");
    }
    const auto choice = MessageBoxW(
        nullptr,
        L"\u76ee\u6807\u6587\u4ef6\u5df2\u7ecf\u88ab\u5916\u90e8\u5e94\u7528\u5360\u7528\uff0c"
        L"Windows \u4e0d\u5141\u8bb8\u8986\u76d6\u8be5\u6587\u4ef6\u3002\r\n\r\n"
        L"\u8bf7\u5173\u95ed\u5360\u7528\u8be5\u6587\u4ef6\u7684\u5e94\u7528\u540e\u91cd\u8bd5\u3002",
        L"PDF \u6587\u4ef6\u88ab\u5360\u7528",
        MB_RETRYCANCEL | MB_ICONWARNING | MB_SETFOREGROUND | MB_TOPMOST);
    if (choice != IDRETRY) return 2;
  }
  DWORD written = 0;
  const auto write_ok = WriteFile(file, document.data(),
                                  static_cast<DWORD>(document.size()), &written,
                                  nullptr);
  CloseHandle(file);
  if (!write_ok || written != document.size()) {
    return FailWin32("Could not write the output PDF");
  }
  printf("PROGRESS %d %d\n", page_count, page_count);
  printf("RESULT 1\n");
  fflush(stdout);
  LogPrintStage("worker_direct_pdf_saved");
  return 0;
}

}  // namespace

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, wchar_t*, int) {
  if (__argc != 5) {
    return Fail("Usage: debug_pdf_printer <pdf> <name> <width> <height>");
  }
  const std::wstring pdf_path = __wargv[1];
  const std::wstring document_name = __wargv[2];
  const auto width = wcstod(__wargv[3], nullptr);
  const auto height = wcstod(__wargv[4], nullptr);

  std::ifstream input(pdf_path, std::ios::binary | std::ios::ate);
  if (!input) {
    return Fail("Could not open the temporary PDF.");
  }
  const auto file_size = input.tellg();
  if (file_size <= 0) {
    return Fail("The temporary PDF is empty.");
  }
  std::vector<uint8_t> document(static_cast<size_t>(file_size));
  input.seekg(0, std::ios::beg);
  input.read(reinterpret_cast<char*>(document.data()), file_size);
  if (!input) {
    return Fail("Could not read the temporary PDF.");
  }

  const auto com_result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(com_result)) {
    return Fail("Could not initialize printing.");
  }

  HGLOBAL dev_mode = GlobalAlloc(GPTR, sizeof(DEVMODE));
  if (dev_mode == nullptr) {
    CoUninitialize();
    return Fail("Could not allocate print settings.");
  }
  auto* mode = static_cast<DEVMODE*>(GlobalLock(dev_mode));
  mode->dmSize = sizeof(DEVMODE);
  mode->dmFields = DM_ORIENTATION | DM_PAPERSIZE | DM_PAPERLENGTH |
                   DM_PAPERWIDTH;
  mode->dmPaperSize = 0;
  if (width > height) {
    mode->dmOrientation = DMORIENT_LANDSCAPE;
    mode->dmPaperWidth = static_cast<short>(std::lround(height * 254 / 72));
    mode->dmPaperLength = static_cast<short>(std::lround(width * 254 / 72));
  } else {
    mode->dmOrientation = DMORIENT_PORTRAIT;
    mode->dmPaperWidth = static_cast<short>(std::lround(width * 254 / 72));
    mode->dmPaperLength = static_cast<short>(std::lround(height * 254 / 72));
  }
  GlobalUnlock(dev_mode);

  PRINTDLG dialog{};
  dialog.lStructSize = sizeof(dialog);
  dialog.hDevMode = dev_mode;
  dialog.Flags = PD_USEDEVMODECOPIES | PD_RETURNDC | PD_PRINTSETUP |
                 PD_NOSELECTION | PD_NOPAGENUMS;
  dialog.nCopies = 1;
  dialog.nFromPage = 0xFFFF;
  dialog.nToPage = 0xFFFF;
  dialog.nMinPage = 1;
  dialog.nMaxPage = 0xFFFF;

  HDC hdc = nullptr;
  LogPrintStage("worker_before_dialog");
  const auto accepted = PrintDlg(&dialog) == 1;
  LogPrintStage("worker_after_dialog");
  if (accepted) {
    hdc = dialog.hDC;
  }
  auto cleanup = [&]() {
    if (hdc != nullptr) {
      DeleteDC(hdc);
    }
    if (dialog.hDevMode != nullptr) {
      GlobalFree(dialog.hDevMode);
    }
    if (dialog.hDevNames != nullptr) {
      GlobalFree(dialog.hDevNames);
    }
  };
  if (!accepted) {
    cleanup();
    CoUninitialize();
    return 2;
  }
  if (IsPdfPrinter(dialog)) {
    const auto result = SavePdfDirectly(document, document_name);
    cleanup();
    CoUninitialize();
    return result;
  }

  DOCINFO doc_info{};
  doc_info.cbSize = sizeof(doc_info);
  doc_info.lpszDocName = document_name.c_str();
  LogPrintStage("worker_before_start_doc");
  if (StartDoc(hdc, &doc_info) <= 0) {
    cleanup();
    CoUninitialize();
    return FailWin32("Could not start the print job");
  }
  LogPrintStage("worker_after_start_doc");

  FPDF_LIBRARY_CONFIG config{};
  config.version = 2;
  FPDF_InitLibraryWithConfig(&config);
  auto pdf = FPDF_LoadMemDocument64(document.data(), document.size(), nullptr);
  if (pdf == nullptr) {
    FPDF_DestroyLibrary();
    EndDoc(hdc);
    cleanup();
    CoUninitialize();
    return Fail("Could not open the generated PDF.");
  }

  const auto dpi_x = GetDeviceCaps(hdc, LOGPIXELSX) / 72.0;
  const auto dpi_y = GetDeviceCaps(hdc, LOGPIXELSY) / 72.0;
  const auto margin_left = GetDeviceCaps(hdc, PHYSICALOFFSETX);
  const auto margin_top = GetDeviceCaps(hdc, PHYSICALOFFSETY);
  const auto page_count = FPDF_GetPageCount(pdf);
  auto succeeded = true;
  for (int page_number = 0; page_number < page_count; ++page_number) {
    LogPrintStage("worker_before_start_page");
    if (StartPage(hdc) <= 0) {
      succeeded = false;
      break;
    }
    auto page = FPDF_LoadPage(pdf, page_number);
    if (page == nullptr) {
      EndPage(hdc);
      succeeded = false;
      break;
    }
    const auto bitmap_width =
        static_cast<int>(FPDF_GetPageWidth(page) * dpi_x);
    const auto bitmap_height =
        static_cast<int>(FPDF_GetPageHeight(page) * dpi_y);
    FPDF_RenderPage(hdc, page, -margin_left, -margin_top, bitmap_width,
                    bitmap_height, 0, FPDF_ANNOT | FPDF_PRINTING);
    FPDF_ClosePage(page);
    LogPrintStage("worker_before_end_page");
    if (EndPage(hdc) <= 0) {
      succeeded = false;
      break;
    }
    LogPrintStage("worker_after_end_page");
    printf("PROGRESS %d %d\n", page_number + 1, page_count);
    fflush(stdout);
  }

  FPDF_CloseDocument(pdf);
  FPDF_DestroyLibrary();
  EndDoc(hdc);
  cleanup();
  CoUninitialize();
  LogPrintStage("worker_complete");
  if (!succeeded) {
    return Fail("The printer did not accept every page.");
  }
  printf("RESULT 1\n");
  fflush(stdout);
  return 0;
}
