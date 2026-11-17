const state = {
  user: null,
  profiles: [],
  countries: [],
  matches: [],
  notifications: [],
  conversations: [],
  contacts: [],
  activeMatchId: null,
  isLoading: false
};

const elements = {
  loginCta: document.getElementById('loginCta'),
  logoutButton: document.getElementById('logoutButton'),
  registrationForm: document.getElementById('registrationForm'),
  loginForm: document.getElementById('loginForm'),
  forgotPasswordToggle: document.getElementById('forgotPasswordToggle'),
  passwordResetPanel: document.getElementById('passwordResetPanel'),
  forgotPasswordForm: document.getElementById('forgotPasswordForm'),
  resetPasswordForm: document.getElementById('resetPasswordForm'),
  profileSummary: document.getElementById('profileSummary'),
  notificationCount: document.getElementById('notificationCount'),
  notificationList: document.getElementById('notificationList'),
  matchList: document.getElementById('matchList'),
  profileForm: document.getElementById('profileForm'),
  saveProfileBtn: document.getElementById('saveProfileBtn'),
  searchInput: document.getElementById('searchInput'),
  genderFilter: document.getElementById('genderFilter'),
  countryFilter: document.getElementById('countryFilter'),
  discoverList: document.getElementById('discoverList'),
  conversationList: document.getElementById('conversationList'),
  chatHeader: document.getElementById('chatHeader'),
  chatMessages: document.getElementById('chatMessages'),
  messageForm: document.getElementById('messageForm'),
  adminSection: document.getElementById('adminSection'),
  adminReports: document.getElementById('adminReports')
};

function showToast(message, isError = false) {
  let region = document.getElementById('toastRegion');
  if (!region) {
    region = document.createElement('div');
    region.id = 'toastRegion';
    region.className = 'toast-region';
    region.setAttribute('role', 'status');
    region.setAttribute('aria-live', 'polite');
    document.body.append(region);
  }
  region.textContent = message;
  region.classList.toggle('toast-error', isError);
  region.classList.add('visible');
  window.clearTimeout(showToast.timeoutId);
  showToast.timeoutId = window.setTimeout(() => region.classList.remove('visible'), 3600);
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    credentials: 'same-origin',
    headers: {
      ...(options.body ? { 'Content-Type': 'application/json' } : {}),
      ...options.headers
    }
  });
  const payload = response.status === 204 ? null : await response.json();
  if (!response.ok) {
    throw new Error(payload?.error || `Request failed (${response.status}).`);
  }
  return payload;
}

function setActivePage(pageId) {
  document.querySelectorAll('.page').forEach((page) => {
    page.classList.toggle('active', page.id === pageId);
    if (page.id === 'app' && !state.user) page.classList.remove('active');
  });
  document.querySelectorAll('.nav-link').forEach((link) => {
    link.classList.toggle('active', link.dataset.target === pageId);
  });
}

function showSignedInState() {
  const signedIn = Boolean(state.user);
  elements.logoutButton.classList.toggle('hidden', !signedIn);
  elements.loginCta.classList.toggle('hidden', signedIn);
  document.querySelector('.nav-link[data-target="auth"]').classList.toggle('hidden', signedIn);
  document.getElementById('app').classList.toggle('hidden', !signedIn);
  document.getElementById('auth').classList.toggle('hidden', signedIn);
  setActivePage(signedIn ? 'app' : 'home');
  if (signedIn) renderProfileSummary();
}

function createElement(tag, className, text) {
  const element = document.createElement(tag);
  if (className) element.className = className;
  if (text !== undefined) element.textContent = text;
  return element;
}

function createButton(text, className, handler, attributes = {}) {
  const button = createElement('button', className, text);
  button.type = 'button';
  Object.entries(attributes).forEach(([name, value]) => button.setAttribute(name, value));
  button.addEventListener('click', handler);
  return button;
}

function clear(element) {
  element.replaceChildren();
}

function renderProfileSummary() {
  clear(elements.profileSummary);
  if (!state.user) return;

  const avatar = createElement('div', 'avatar avatar-three', state.user.displayName.slice(0, 1).toUpperCase());
  const details = createElement('div');
  details.append(
    createElement('strong', '', state.user.displayName),
    createElement('small', '', `${state.user.city || 'Location hidden'} • ${state.user.age} years`)
  );
  elements.profileSummary.append(avatar, details);

  const form = elements.profileForm;
  form.elements.displayName.value = state.user.displayName || '';
  form.elements.relationshipIntent.value = state.user.relationshipIntent || 'Long-term relationship';
  form.elements.country.value = state.user.country || '';
  form.elements.city.value = state.user.city || '';
  form.elements.occupation.value = state.user.occupation || '';
  form.elements.education.value = state.user.education || '';
  form.elements.aboutMe.value = state.user.aboutMe || '';
  form.elements.interests.value = (state.user.interests || []).join(', ');
  form.elements.languages.value = (state.user.languages || []).join(', ');
  form.elements.ageRange.value = state.user.ageRange || '';
  form.elements.preferredLocation.value = state.user.preferredLocation || '';
}

function renderNotifications() {
  clear(elements.notificationList);
  const notifications = state.notifications;
  elements.notificationCount.textContent = String(notifications.filter((item) => !item.read).length);
  if (!notifications.length) {
    elements.notificationList.append(createElement('p', 'muted-empty', 'No notifications yet.'));
    return;
  }

  notifications.forEach((notification) => {
    const card = createElement('div', 'notification-item');
    const meta = createElement('div', 'notification-meta');
    meta.append(
      createElement('strong', '', notification.type.toUpperCase()),
      createElement('span', '', notification.read ? 'Read' : 'New')
    );
    card.append(meta, createElement('p', '', notification.text));
    if (notification.type === 'contact' && notification.canRespond && notification.requestId) {
      const actions = createElement('div', 'notification-actions');
      actions.append(
        createButton('Accept', 'btn btn-primary', () => decideContact(notification, 'accept')),
        createButton('Decline', 'btn btn-secondary', () => decideContact(notification, 'decline'))
      );
      card.append(actions);
    }
    elements.notificationList.append(card);
  });
}

function renderMatches() {
  clear(elements.matchList);
  if (!state.matches.length) {
    elements.matchList.append(createElement('p', 'muted-empty', 'Mutual likes create your first match.'));
    return;
  }

  state.matches.forEach((match) => {
    const card = createElement('div', 'match-item');
    const meta = createElement('div', 'match-meta');
    meta.append(
      createElement('strong', '', match.displayName),
      createElement('span', '', new Date(match.matchedAt).toLocaleDateString())
    );
    card.append(meta, createElement('p', '', 'A private conversation is ready.'));
    const contact = state.contacts.find((item) => item.userId === match.userId);
    if (contact) {
      const details = createElement('p', 'contact-details');
      details.textContent = [contact.email, contact.phone].filter(Boolean).join(' • ') || 'No contact details provided.';
      card.append(details);
    } else {
      card.append(createButton('Request contact exchange', 'btn btn-light small-btn', async () => {
        try {
          await api('/api/contact-requests', {
            method: 'POST',
            body: JSON.stringify({ targetId: match.userId })
          });
          await refreshData();
          showToast('Contact exchange request sent.');
        } catch (error) {
          showToast(error.message, true);
        }
      }));
    }
    card.append(createButton('Open conversation', 'btn btn-secondary small-btn', () => {
      const conversation = state.conversations.find((item) => item.matchId === match.id);
      if (conversation) {
        state.activeMatchId = match.id;
        renderConversations();
        document.getElementById('messagesSection').scrollIntoView({ behavior: 'smooth', block: 'start' });
      }
    }));
    elements.matchList.append(card);
  });
}

function renderCountries() {
  const selectedCountry = elements.countryFilter.value || 'all';
  clear(elements.countryFilter);
  const allOption = createElement('option', '', 'All countries');
  allOption.value = 'all';
  elements.countryFilter.append(allOption);
  state.countries.forEach((country) => {
    const option = createElement('option', '', country);
    option.value = country;
    elements.countryFilter.append(option);
  });
  elements.countryFilter.value = state.countries.includes(selectedCountry) ? selectedCountry : 'all';
}

function renderDiscover() {
  clear(elements.discoverList);
  if (!state.profiles.length) {
    elements.discoverList.append(createElement('p', 'muted-empty', 'No profiles found. Invite someone to join, or try different filters.'));
    return;
  }

  state.profiles.forEach((profile) => {
    const card = createElement('article', 'profile-item');
    const header = createElement('div', 'profile-item-header');
    const avatar = createElement('div', 'avatar avatar-two', profile.displayName.slice(0, 1).toUpperCase());
    const identity = createElement('div');
    identity.append(
      createElement('strong', '', profile.displayName),
      createElement('small', '', `${profile.age} • ${profile.city || 'Location private'} • ${profile.country || 'Country private'}`)
    );
    header.append(avatar, identity);
    card.append(header, createElement('p', '', profile.aboutMe || 'No bio yet.'));

    const badges = createElement('div', 'badge-row');
    badges.append(
      createElement('span', 'tag tag-neutral', profile.gender),
      createElement('span', 'tag tag-neutral', profile.relationshipIntent || 'Open to connect')
    );
    card.append(badges);

    const footer = createElement('div', 'profile-item-footer');
    const actions = createElement('div', 'action-row');
    actions.append(
      createButton('Like', 'btn btn-primary', () => submitInterest(profile, 'like')),
      createButton('Pass', 'btn btn-secondary', () => submitInterest(profile, 'pass'))
    );
    footer.append(actions);
    footer.append(createButton('Report', 'btn btn-light', () => reportProfile(profile)));
    card.append(footer);
    elements.discoverList.append(card);
  });
}

function renderConversations() {
  clear(elements.conversationList);
  const active = state.conversations.find((item) => item.matchId === state.activeMatchId) || state.conversations[0];
  if (!active) {
    state.activeMatchId = null;
    elements.chatHeader.textContent = 'No conversation yet';
    clear(elements.chatMessages);
    elements.chatMessages.append(createElement('p', 'muted-empty', 'You can message someone after you match.'));
    elements.messageForm.elements.message.disabled = true;
    elements.messageForm.querySelector('button').disabled = true;
    return;
  }

  state.activeMatchId = active.matchId;
  elements.messageForm.elements.message.disabled = false;
  elements.messageForm.querySelector('button').disabled = false;
  state.conversations.forEach((conversation) => {
    const messages = Array.isArray(conversation.messages) ? conversation.messages : (conversation.messages ? [conversation.messages] : []);
    const button = createButton(
      '',
      `conversation-item ${conversation.matchId === active.matchId ? 'active' : ''}`,
      () => {
        state.activeMatchId = conversation.matchId;
        renderConversations();
      }
    );
    button.append(
      createElement('strong', '', conversation.displayName),
      createElement('span', '', messages.at(-1)?.text || 'Start a conversation')
    );
    elements.conversationList.append(button);
  });

  elements.chatHeader.textContent = `${active.displayName} • private conversation`;
  clear(elements.chatMessages);
  const messages = Array.isArray(active.messages) ? active.messages : (active.messages ? [active.messages] : []);
  if (!messages.length) {
    elements.chatMessages.append(createElement('p', 'muted-empty', 'Say hello to start the conversation.'));
  } else {
    messages.forEach((message) => {
      const bubble = createElement(
        'div',
        `chat-bubble ${message.senderId === state.user.id ? 'mine' : 'theirs'}`,
        message.text
      );
      bubble.title = new Date(message.createdAt).toLocaleString();
      elements.chatMessages.append(bubble);
    });
    elements.chatMessages.scrollTop = elements.chatMessages.scrollHeight;
  }
}

function renderAdminReports(reports) {
  clear(elements.adminReports);
  if (!reports.length) {
    elements.adminReports.append(createElement('p', 'muted-empty', 'No reports have been filed.'));
    return;
  }
  reports.forEach((report) => {
    const row = createElement('div', 'report-row');
    const identity = createElement('strong', '', report.displayName);
    const reason = createElement('span', '', report.reason);
    const status = createElement('span', '', report.status);
    const actions = createElement('div', 'admin-report-actions');
    const select = createElement('select');
    [
      ['reviewing', 'Reviewing'],
      ['resolved', 'Resolved'],
      ['dismissed', 'Dismissed']
    ].forEach(([value, label]) => {
      const option = createElement('option', '', label);
      option.value = value;
      option.selected = report.status === value;
      select.append(option);
    });
    const updateButton = createButton('Update', 'btn btn-secondary small-btn', async () => {
      try {
        await api('/api/admin/reports', {
          method: 'PUT',
          body: JSON.stringify({ reportId: report.id, status: select.value })
        });
        await refreshData();
        showToast('Report status updated.');
      } catch (error) {
        showToast(error.message, true);
      }
    });
    actions.append(select, updateButton);
    row.append(
      identity,
      reason,
      status,
      actions
    );
    elements.adminReports.append(row);
  });
}

async function refreshData() {
  if (!state.user) return;
  const [profiles, notifications, matches, conversations, contacts] = await Promise.all([
    api(`/api/profiles?search=${encodeURIComponent(elements.searchInput.value.trim())}&gender=${encodeURIComponent(elements.genderFilter.value)}&country=${encodeURIComponent(elements.countryFilter.value)}`),
    api('/api/notifications'),
    api('/api/matches'),
    api('/api/conversations'),
    api('/api/contacts')
  ]);
  state.profiles = profiles.profiles;
  state.countries = profiles.countries;
  state.notifications = notifications;
  state.matches = matches;
  state.conversations = conversations;
  state.contacts = contacts;
  renderCountries();
  renderNotifications();
  renderMatches();
  renderDiscover();
  renderConversations();
  if (state.user.isAdmin) {
    const [reports, stats] = await Promise.all([
      api('/api/admin/reports'),
      api('/api/admin/stats')
    ]);
    renderAdminReports(reports);
    document.getElementById('adminUserCount').textContent = String(stats.users);
    document.getElementById('adminMatchCount').textContent = String(stats.matches);
    document.getElementById('adminReportCount').textContent = String(stats.openReports);
    elements.adminSection.classList.remove('hidden');
  } else {
    elements.adminSection.classList.add('hidden');
  }
}

async function authenticate(path, form) {
  const values = new FormData(form);
  const payload = Object.fromEntries(values.entries());
  if (path === '/api/register') {
    payload.termsAccepted = values.get('terms') === 'on';
  }
  const user = await api(path, { method: 'POST', body: JSON.stringify(payload) });
  state.user = user;
  showSignedInState();
  await refreshData();
  form.reset();
  showToast(path === '/api/register' ? 'Your account is ready.' : 'Welcome back.');
}

async function requestPasswordReset(event) {
  event.preventDefault();
  const email = new FormData(elements.forgotPasswordForm).get('email');
  try {
    await api('/api/password-reset/request', {
      method: 'POST',
      body: JSON.stringify({ email })
    });
    showToast('Reset link token generated. Use it to set a new password.');
    elements.forgotPasswordForm.reset();
  } catch (error) {
    showToast(error.message, true);
  }
}

async function resetPassword(event) {
  event.preventDefault();
  const values = new FormData(elements.resetPasswordForm);
  const payload = Object.fromEntries(values.entries());
  try {
    await api('/api/password-reset/confirm', {
      method: 'POST',
      body: JSON.stringify(payload)
    });
    showToast('Password updated. Please sign in again.');
    elements.resetPasswordForm.reset();
    elements.passwordResetPanel.classList.add('hidden');
  } catch (error) {
    showToast(error.message, true);
  }
}

async function submitInterest(profile, action) {
  try {
    await api('/api/interests', {
      method: 'POST',
      body: JSON.stringify({ targetId: profile.id, action })
    });
    await refreshData();
    showToast(action === 'like' ? `Interest sent to ${profile.displayName}.` : 'Profile passed.');
  } catch (error) {
    showToast(error.message, true);
  }
}

async function decideContact(notification, decision) {
  try {
    await api('/api/contact-decisions', {
      method: 'POST',
      body: JSON.stringify({ requestId: notification.requestId, decision })
    });
    await refreshData();
    showToast(decision === 'accept' ? 'Contact exchange accepted.' : 'Request declined.');
  } catch (error) {
    showToast(error.message, true);
  }
}

async function reportProfile(profile) {
  const reason = window.prompt(`Why are you reporting ${profile.displayName}?`);
  if (!reason) return;
  try {
    await api('/api/reports', {
      method: 'POST',
      body: JSON.stringify({ targetId: profile.id, reason })
    });
    showToast('Report received. Thank you for helping keep the community safe.');
  } catch (error) {
    showToast(error.message, true);
  }
}

async function saveProfile(event) {
  event.preventDefault();
  const values = new FormData(elements.profileForm);
  const payload = Object.fromEntries(values.entries());
  payload.interests = String(payload.interests || '').split(',').map((item) => item.trim()).filter(Boolean);
  payload.languages = String(payload.languages || '').split(',').map((item) => item.trim()).filter(Boolean);
  try {
    state.user = await api('/api/profile', { method: 'PUT', body: JSON.stringify(payload) });
    renderProfileSummary();
    await refreshData();
    showToast('Profile saved.');
  } catch (error) {
    showToast(error.message, true);
  }
}

async function sendMessage(event) {
  event.preventDefault();
  const text = elements.messageForm.elements.message.value.trim();
  if (!text || !state.activeMatchId) return;
  try {
    await api('/api/messages', {
      method: 'POST',
      body: JSON.stringify({ matchId: state.activeMatchId, text })
    });
    elements.messageForm.reset();
    await refreshData();
  } catch (error) {
    showToast(error.message, true);
  }
}

async function logout() {
  try {
    await api('/api/logout', { method: 'POST' });
    state.user = null;
    state.profiles = [];
    state.matches = [];
    state.notifications = [];
    state.conversations = [];
    state.contacts = [];
    showSignedInState();
    showToast('You have been signed out.');
  } catch (error) {
    showToast(error.message, true);
  }
}

function bindEvents() {
  document.querySelectorAll('button[data-target]').forEach((button) => {
    button.addEventListener('click', () => {
      const target = button.dataset.target;
      if (target === 'app' && !state.user) {
        showToast('Create an account or sign in to access member profiles.', true);
        setActivePage('auth');
        return;
      }
      setActivePage(target);
    });
  });
  elements.loginCta.addEventListener('click', () => setActivePage('auth'));
  elements.forgotPasswordToggle.addEventListener('click', () => {
    elements.passwordResetPanel.classList.toggle('hidden');
  });
  elements.logoutButton.addEventListener('click', logout);
  elements.registrationForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    try {
      await authenticate('/api/register', event.currentTarget);
    } catch (error) {
      showToast(error.message, true);
    }
  });
  elements.loginForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    try {
      await authenticate('/api/login', event.currentTarget);
    } catch (error) {
      showToast(error.message, true);
    }
  });
  elements.profileForm.addEventListener('submit', saveProfile);
  elements.saveProfileBtn.addEventListener('click', () => elements.profileForm.requestSubmit());
  elements.searchInput.addEventListener('input', debounce(() => refreshData().catch((error) => showToast(error.message, true)), 250));
  elements.genderFilter.addEventListener('change', () => refreshData().catch((error) => showToast(error.message, true)));
  elements.countryFilter.addEventListener('change', () => refreshData().catch((error) => showToast(error.message, true)));
  elements.forgotPasswordForm.addEventListener('submit', requestPasswordReset);
  elements.resetPasswordForm.addEventListener('submit', resetPassword);
  elements.messageForm.addEventListener('submit', sendMessage);
}

function debounce(callback, delay) {
  let timeoutId;
  return (...args) => {
    window.clearTimeout(timeoutId);
    timeoutId = window.setTimeout(() => callback(...args), delay);
  };
}

async function initialize() {
  bindEvents();
  try {
    state.user = await api('/api/me');
    showSignedInState();
    await refreshData();
  } catch (error) {
    if (!error.message.includes('sign in')) showToast(error.message, true);
    state.user = null;
    showSignedInState();
  }
}

initialize();
