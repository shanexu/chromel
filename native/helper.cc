// SPDX-License-Identifier: GPL-3.0-or-later
#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/cef_process_message.h"
#include "include/cef_v8.h"
#include "include/cef_dom.h"
#include "chromel_scripts.h"

namespace {
// Only the browser process can request evaluation.  No native API is exposed
// to page JavaScript, and replies are data, never Lisp code.
class RendererApp final : public CefApp, public CefRenderProcessHandler {
 public:
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }
  void OnContextCreated(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                        CefRefPtr<CefV8Context> context) override {
    if (!context->Enter()) return;
    CefRefPtr<CefV8Value> result;
    CefRefPtr<CefV8Exception> exception;
    context->Eval(kChromelScrollBootstrap, "", 1, result, exception);
    context->Exit();
  }
  void OnFocusedNodeChanged(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                            CefRefPtr<CefDOMNode> node) override {
    if (!frame) return;
    const auto tag = node && node->IsElement() ? node->GetElementTagName().ToString() : "";
    auto message = CefProcessMessage::Create("chromel.input-focus");
    message->GetArgumentList()->SetBool(0, node &&
      (node->IsEditable() || tag == "SELECT" || tag == "INPUT" || tag == "TEXTAREA" ||
       tag == "EMBED" || tag == "OBJECT"));
    frame->SendProcessMessage(PID_BROWSER, message);
  }
  bool OnProcessMessageReceived(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame,
                                CefProcessId source, CefRefPtr<CefProcessMessage> message) override {
    const bool execute = message->GetName() == "chromel.execute-script";
    if (source != PID_BROWSER || (!execute && message->GetName() != "chromel.eval") ||
        !frame || !frame->IsMain())
      return false;
    auto input = message->GetArgumentList();
    if (!input || input->GetSize() < 2) return true;
    auto reply = CefProcessMessage::Create(execute ? "chromel.execute-script.result"
                                                   : "chromel.eval.result");
    auto output = reply->GetArgumentList();
    output->SetString(0, input->GetString(0));
    output->SetBool(1, false);
    output->SetString(2, "Page JavaScript context is not ready");
    if (execute) output->SetBool(3, false);
    auto context = frame->GetV8Context();
    if (context && context->Enter()) {
      CefRefPtr<CefV8Value> value;
      CefRefPtr<CefV8Exception> exception;
      const bool ok = context->Eval(input->GetString(1), "", 1, value, exception);
      if (execute && ok && value) {
        if (value->IsUndefined()) {
          output->SetBool(1, true);
          output->SetBool(3, true);
          output->SetString(2, "");
        } else if (value->IsPromise()) {
          // Awaiting would need a microtask loop the renderer does not have.
          output->SetString(2, "Promise results are not awaited; return a synchronous value");
        } else {
          // Serialize the value, not the source: top-level JavaScript keeps its
          // normal semantics and the script is never evaluated twice.
          CefRefPtr<CefV8Value> serializer;
          CefRefPtr<CefV8Exception> serializationException;
          if (context->Eval("(value => JSON.stringify(value))", "", 1, serializer,
                            serializationException) &&
              serializer && serializer->IsFunction()) {
            auto encoded = serializer->ExecuteFunction(nullptr, {value});
            if (encoded && encoded->IsString()) {
              output->SetBool(1, true);
              output->SetString(2, encoded->GetStringValue());
            } else {
              auto error = serializer->GetException();
              output->SetString(2, error ? error->GetMessage()
                                         : CefString("Result is not JSON-serializable"));
            }
          } else {
            output->SetString(2, serializationException
                                     ? serializationException->GetMessage()
                                     : CefString("Unable to serialize JavaScript result"));
          }
        }
      } else if (ok && value && value->IsString()) {
        output->SetBool(1, true);
        output->SetString(2, value->GetStringValue());
      } else {
        output->SetString(2, exception ? exception->GetMessage() : CefString("Expected a JSON string result"));
      }
      context->Exit();
    }
    frame->SendProcessMessage(PID_BROWSER, reply);
    return true;
  }
 private:
  IMPLEMENT_REFCOUNTING(RendererApp);
};
}

int main(int argc, char** argv) {
  // The sandbox must be initialized before the Chromium framework is loaded.
  CefScopedSandboxContext sandbox;
  if (!sandbox.Initialize(argc, argv)) return 1;
  CefScopedLibraryLoader loader;
  if (!loader.LoadInHelper()) return 2;
  return CefExecuteProcess(CefMainArgs(argc, argv), new RendererApp, nullptr);
}
