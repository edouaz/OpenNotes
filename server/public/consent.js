(async () => {
  const message = document.querySelector('#message'), form = document.querySelector('#login'), consent = document.querySelector('#consent');
  const authorization = new URL(location.href).searchParams.get('authorization_id');
  if (!authorization) {
    if (location.hash) history.replaceState(null, '', location.pathname + location.search);
    message.textContent = 'Return to OpenNotes and sign in under Account and cloud to sync your notebooks. To connect an assistant, start the connection from your chatbot.';
    return;
  }
  const config = await (await fetch('/oauth/config')).json();
  const client = supabase.createClient(config.supabaseURL, config.publishableKey);
  async function show() {
    const { data: user, error: userError } = await client.auth.getUser();
    if (userError || !user.user) { form.hidden = false; return; }
    form.hidden = true;
    const { data, error } = await client.auth.oauth.getAuthorizationDetails(authorization);
    if (error) { message.textContent = error.message; return; }
    if (data.redirect_url) { location.assign(data.redirect_url); return; }
    document.querySelector('#client').textContent = `Client: ${data.client.name || 'Unknown'}`;
    document.querySelector('#scopes').textContent = `Requested scopes: ${data.scope || 'none'}`;
    consent.hidden = false;
  }
  form.addEventListener('submit', async event => {
    event.preventDefault(); const values = new FormData(form);
    const { error } = await client.auth.signInWithPassword({ email: values.get('email'), password: values.get('password') });
    form.elements.password.value = ''; if (error) message.textContent = error.message; else await show();
  });
  for (const name of ['approve', 'deny']) document.querySelector(`#${name}`).addEventListener('click', async () => {
    const { error } = name === 'approve' ? await client.auth.oauth.approveAuthorization(authorization) : await client.auth.oauth.denyAuthorization(authorization);
    if (error) message.textContent = error.message;
  });
  await show();
})().catch(() => { console.error('Authorization page initialization failed.'); document.querySelector('#message').textContent = 'Unable to load authorization. Please try again.'; });
