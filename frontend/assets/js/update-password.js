"use strict";

document.addEventListener("DOMContentLoaded", () => {
  const checkingPanel = document.getElementById("recoveryCheckingPanel");
  const invalidPanel = document.getElementById("invalidRecoveryPanel");
  const invalidMessage = document.getElementById("invalidRecoveryMessage");
  const form = document.getElementById("updatePasswordForm");
  const successPanel = document.getElementById("passwordSuccessPanel");

  const newPasswordInput = document.getElementById("newPassword");
  const confirmPasswordInput = document.getElementById("confirmPassword");
  const submitButton = document.getElementById("updatePasswordButton");
  const message = document.getElementById("updatePasswordMessage");

  const toggleNewPassword = document.getElementById("toggleNewPassword");
  const toggleConfirmPassword = document.getElementById(
    "toggleConfirmPassword"
  );

  const ruleElements = {
    length: document.getElementById("ruleLength"),
    uppercase: document.getElementById("ruleUppercase"),
    lowercase: document.getElementById("ruleLowercase"),
    number: document.getElementById("ruleNumber"),
    symbol: document.getElementById("ruleSymbol")
  };

  const client = window.elisSupabase;
  let recoverySessionReady = false;
  let validationFinished = false;

  const hashParameters = new URLSearchParams(
    window.location.hash.startsWith("#")
      ? window.location.hash.slice(1)
      : window.location.hash
  );
  const queryParameters = new URLSearchParams(window.location.search);

  const linkType=hashParameters.get("type")||queryParameters.get("type");
  const recoveryUrlDetected=linkType === "recovery" || linkType === "invite";

  const redirectError =
    hashParameters.get("error_description") ||
    queryParameters.get("error_description");

  function setMessage(text = "", type = "") {
    message.textContent = text;
    message.className = "message";

    if (type) {
      message.classList.add(type);
    }
  }

  function showInvalidRecovery(text) {
    if (validationFinished) {
      return;
    }

    validationFinished = true;
    checkingPanel.classList.add("hidden");
    form.classList.add("hidden");
    successPanel.classList.add("hidden");
    invalidPanel.classList.remove("hidden");
    invalidMessage.textContent = text;
  }

  function showRecoveryForm() {
    if (validationFinished) {
      return;
    }

    validationFinished = true;
    recoverySessionReady = true;
    checkingPanel.classList.add("hidden");
    invalidPanel.classList.add("hidden");
    successPanel.classList.add("hidden");
    form.classList.remove("hidden");

    // Remove recovery tokens from the visible browser address.
    window.history.replaceState(
      {},
      document.title,
      window.location.pathname
    );

    newPasswordInput.focus();
  }

  function showSuccess() {
    form.classList.add("hidden");
    checkingPanel.classList.add("hidden");
    invalidPanel.classList.add("hidden");
    successPanel.classList.remove("hidden");
  }

  function passwordChecks(password) {
    return {
      length: password.length >= 12,
      uppercase: /[A-Z]/.test(password),
      lowercase: /[a-z]/.test(password),
      number: /[0-9]/.test(password),
      symbol: /[^A-Za-z0-9]/.test(password)
    };
  }

  function updatePasswordRules() {
    const checks = passwordChecks(newPasswordInput.value);

    Object.entries(checks).forEach(([rule, isValid]) => {
      ruleElements[rule].classList.toggle("valid", isValid);
    });

    return checks;
  }

  function allRulesPass(checks) {
    return Object.values(checks).every(Boolean);
  }

  function configurePasswordToggle(button, input) {
    button.addEventListener("click", () => {
      const shouldShow = input.type === "password";

      input.type = shouldShow ? "text" : "password";
      button.textContent = shouldShow ? "Hide" : "Show";
      button.setAttribute("aria-pressed", String(shouldShow));
    });
  }

  configurePasswordToggle(toggleNewPassword, newPasswordInput);
  configurePasswordToggle(toggleConfirmPassword, confirmPasswordInput);

  newPasswordInput.addEventListener("input", () => {
    updatePasswordRules();
    setMessage("");
  });

  confirmPasswordInput.addEventListener("input", () => {
    setMessage("");
  });

  if (window.ELIS_SUPABASE_ERROR || !client) {
    showInvalidRecovery(
      window.ELIS_SUPABASE_ERROR ||
        "The Supabase connection could not be initialized."
    );
    return;
  }

  if (redirectError) {
    showInvalidRecovery(redirectError.replace(/\+/g, " "));
    return;
  }

  const {
    data: { subscription }
  } = client.auth.onAuthStateChange((event, session) => {
    if ((event === "PASSWORD_RECOVERY" || (recoveryUrlDetected && ["SIGNED_IN","INITIAL_SESSION"].includes(event))) && session) {
      showRecoveryForm();
    }
  });

  window.addEventListener("pagehide", () => {
    subscription.unsubscribe();
  });

  // Fallback for cases where the auth event was processed before this listener.
  (async function validateRecoverySession() {
    try {
      const {
        data: { session },
        error
      } = await client.auth.getSession();

      if (validationFinished) {
        return;
      }

      if (error) {
        throw error;
      }

      if (recoveryUrlDetected && session) {
        showRecoveryForm();
        return;
      }

      showInvalidRecovery(
        "This password recovery link is invalid or has expired. Request a new link and try again."
      );
    } catch (error) {
      console.error("Recovery session validation failed:", error);
      showInvalidRecovery(
        "The password recovery link could not be validated. Request a new link and try again."
      );
    }
  })();

  form.addEventListener("submit", async (event) => {
    event.preventDefault();

    if (!recoverySessionReady) {
      setMessage(
        "The recovery session is not ready. Request a new recovery link.",
        "error"
      );
      return;
    }

    const newPassword = newPasswordInput.value;
    const confirmPassword = confirmPasswordInput.value;
    const checks = updatePasswordRules();

    if (!allRulesPass(checks)) {
      setMessage(
        "The new password does not meet all password requirements.",
        "error"
      );
      newPasswordInput.focus();
      return;
    }

    if (newPassword !== confirmPassword) {
      setMessage("Passwords do not match.", "error");
      confirmPasswordInput.focus();
      return;
    }

    submitButton.disabled = true;
    submitButton.textContent = "Updating...";
    setMessage("");

    try {
      const { error } = await client.auth.updateUser({
        password: newPassword
      });

      if (error) {
        throw error;
      }

      // Close only the recovery session in this browser.
      const { error: signOutError } = await client.auth.signOut({
        scope: "local"
      });

      if (signOutError) {
        console.warn("Password changed, but local sign-out failed:", signOutError);
      }

      newPasswordInput.value = "";
      confirmPasswordInput.value = "";
      showSuccess();
    } catch (error) {
      console.error("Password update failed:", error);
      setMessage(
        error?.message || "The password could not be updated.",
        "error"
      );
    } finally {
      submitButton.disabled = false;
      submitButton.textContent = "Update password";
    }
  });
});
