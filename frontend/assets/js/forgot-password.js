"use strict";

document.addEventListener("DOMContentLoaded", () => {
  const form = document.getElementById("passwordRecoveryForm");
  const emailInput = document.getElementById("recoveryEmail");
  const submitButton = document.getElementById("recoveryButton");
  const message = document.getElementById("recoveryMessage");

  const client = window.elisSupabase;

  function setMessage(text = "", type = "") {
    message.textContent = text;
    message.className = "message";

    if (type) {
      message.classList.add(type);
    }
  }

  if (window.ELIS_SUPABASE_ERROR || !client) {
    setMessage(
      window.ELIS_SUPABASE_ERROR ||
        "The Supabase connection could not be initialized.",
      "error"
    );

    submitButton.disabled = true;
    return;
  }

  form.addEventListener("submit", async (event) => {
    event.preventDefault();

    const email = emailInput.value.trim();

    if (!email) {
      setMessage("Enter your email address.", "error");
      emailInput.focus();
      return;
    }

    if (!emailInput.checkValidity()) {
      setMessage("Enter a valid email address.", "error");
      emailInput.focus();
      return;
    }

    submitButton.disabled = true;
    submitButton.textContent = "Sending...";
    setMessage("");

    try {
      const redirectTo = new URL(
        "./update-password.html",
        window.location.href
      ).href;

      const { error } = await client.auth.resetPasswordForEmail(email, {
        redirectTo
      });

      if (error) {
        throw error;
      }

      setMessage(
        "If an account exists for this email address, a password recovery link has been sent.",
        "success"
      );

      emailInput.value = "";
    } catch (error) {
      console.error("Password recovery request failed:", error);

      const isRateLimit =
        typeof error?.message === "string" &&
        error.message.toLowerCase().includes("rate limit");

      setMessage(
        isRateLimit
          ? "Too many recovery requests. Wait a few minutes and try again."
          : "The recovery request could not be completed. Please try again.",
        "error"
      );
    } finally {
      submitButton.disabled = false;
      submitButton.textContent = "Send recovery link";
    }
  });
});
