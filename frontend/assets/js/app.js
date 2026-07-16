"use strict";

document.addEventListener("DOMContentLoaded", async () => {
  const loginView = document.getElementById("loginView");
  const appView = document.getElementById("appView");

  const loginForm = document.getElementById("loginForm");
  const emailInput = document.getElementById("email");
  const passwordInput = document.getElementById("password");
  const loginButton = document.getElementById("loginButton");
  const logoutButton = document.getElementById("logoutButton");

  const loginMessage = document.getElementById("loginMessage");
  const appMessage = document.getElementById("appMessage");

  const profileName = document.getElementById("profileName");
  const profileEmail = document.getElementById("profileEmail");
  const employeeCode = document.getElementById("employeeCode");
  const roleList = document.getElementById("roleList");

  const client = window.elisSupabase;

  function setMessage(element, text = "", type = "") {
    element.textContent = text;
    element.className = "message";

    if (type) {
      element.classList.add(type);
    }
  }

  function showLogin() {
    appView.classList.add("hidden");
    loginView.classList.remove("hidden");

    profileName.textContent = "";
    profileEmail.textContent = "";
    employeeCode.textContent = "—";
    roleList.replaceChildren();
  }

  function showApp() {
    loginView.classList.add("hidden");
    appView.classList.remove("hidden");
  }

  function renderRoles(staffRoles) {
    roleList.replaceChildren();

    const activeRoles = (staffRoles || [])
      .filter((staffRole) => staffRole.active)
      .map((staffRole) => staffRole.roles)
      .filter(Boolean);

    if (activeRoles.length === 0) {
      const empty = document.createElement("span");
      empty.textContent = "Nenhuma função ativa";
      empty.className = "muted";
      roleList.appendChild(empty);
      return;
    }

    activeRoles.forEach((role) => {
      const badge = document.createElement("span");
      badge.className = "role-badge";
      badge.textContent = role.role_code;
      badge.title = role.role_name;
      roleList.appendChild(badge);
    });
  }

  async function loadAuthenticatedProfile(user) {
    setMessage(appMessage, "Carregando perfil...");

    const { data: profile, error } = await client
      .from("staff_members")
      .select(`
        staff_id,
        employee_code,
        display_name,
        active,
        staff_roles (
          active,
          effective_from,
          effective_until,
          roles (
            role_code,
            role_name
          )
        )
      `)
      .eq("auth_user_id", user.id)
      .eq("active", true)
      .is("deleted_at", null)
      .maybeSingle();

    if (error) {
      console.error("Erro ao carregar perfil:", error);
      throw new Error(
        "O login funcionou, mas não foi possível carregar o perfil de staff."
      );
    }

    if (!profile) {
      throw new Error(
        "Usuário autenticado, mas sem perfil ativo em staff_members."
      );
    }

    profileName.textContent = profile.display_name;
    profileEmail.textContent = user.email || "";
    employeeCode.textContent = profile.employee_code || "Não informado";
    renderRoles(profile.staff_roles);

    showApp();
    setMessage(appMessage, "Login confirmado.", "success");
  }

  if (window.ELIS_SUPABASE_ERROR || !client) {
    setMessage(
      loginMessage,
      window.ELIS_SUPABASE_ERROR ||
        "Não foi possível iniciar a conexão com o Supabase.",
      "error"
    );

    loginButton.disabled = true;
    return;
  }

  try {
    const {
      data: { session },
      error
    } = await client.auth.getSession();

    if (error) {
      throw error;
    }

    if (session?.user) {
      await loadAuthenticatedProfile(session.user);
    } else {
      showLogin();
    }
  } catch (error) {
    console.error("Erro ao restaurar sessão:", error);
    showLogin();
    setMessage(loginMessage, error.message, "error");
  }

  loginForm.addEventListener("submit", async (event) => {
    event.preventDefault();

    const email = emailInput.value.trim();
    const password = passwordInput.value;

    if (!email || !password) {
      setMessage(
        loginMessage,
        "Preencha o e-mail e a senha.",
        "error"
      );
      return;
    }

    loginButton.disabled = true;
    loginButton.textContent = "Entrando...";
    setMessage(loginMessage, "");

    try {
      const { data, error } = await client.auth.signInWithPassword({
        email,
        password
      });

      if (error) {
        throw error;
      }

      if (!data.user) {
        throw new Error("O Supabase não retornou o usuário autenticado.");
      }

      await loadAuthenticatedProfile(data.user);
      passwordInput.value = "";
    } catch (error) {
      console.error("Erro no login:", error);

      await client.auth.signOut();

      showLogin();

      const friendlyMessage =
        error.message === "Invalid login credentials"
          ? "E-mail ou senha incorretos."
          : error.message;

      setMessage(loginMessage, friendlyMessage, "error");
    } finally {
      loginButton.disabled = false;
      loginButton.textContent = "Entrar";
    }
  });

  logoutButton.addEventListener("click", async () => {
    logoutButton.disabled = true;
    logoutButton.textContent = "Saindo...";

    try {
      const { error } = await client.auth.signOut();

      if (error) {
        throw error;
      }

      emailInput.value = "";
      passwordInput.value = "";
      setMessage(loginMessage, "Sessão encerrada.", "success");
      showLogin();
    } catch (error) {
      console.error("Erro ao sair:", error);
      setMessage(appMessage, "Não foi possível encerrar a sessão.", "error");
    } finally {
      logoutButton.disabled = false;
      logoutButton.textContent = "Sair";
    }
  });
});
