<!DOCTYPE html>
<html class="gl-system" lang="en">
<head>
<meta content="width=device-width, initial-scale=1" name="viewport">
<title>Not Found</title>
<script nonce="nMSUVLNItAyIfghvWX3yuw==">
//<![CDATA[
const root = document.documentElement;
if (window.matchMedia('(prefers-color-scheme: dark)').matches) {
  root.classList.add('gl-dark');
}

window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (e) => {
  if (e.matches) {
    root.classList.add('gl-dark');
  } else {
    root.classList.remove('gl-dark');
  }
});

//]]>
</script>
<link rel="stylesheet" href="/assets/errors-b0c92b37a185fd3acdddddf194d494c740f23e037cacb9239e2e6d65ea6404e6.css" />
<link rel="stylesheet" href="/assets/application-8218060a1ac0d2dd1fc923d8fca6a17256f4acf8e3397d1fde3ed3fd1de82e7b.css" />
<link rel="stylesheet" href="/assets/fonts-deb7ad1d55ca77c0172d8538d53442af63604ff490c74acc2859db295c125bdb.css" />
<link rel="stylesheet" href="/assets/tailwind-238d9c0c62b377cbcdb42c7232991bf53d0ce223681d725a5f2c40ed4320a263.css" />
</head>
<body>
<div class="page-container">
<div class="error-container">
<img alt="404" src="/assets/illustrations/error/error-404-lg-9dfb20cc79e1fe8104e0adb122a710283a187b075b15187e2f184d936a16349c.svg" />
<h1>
404: Page not found
</h1>
<p>
Make sure the address is correct and the page has not moved.
Please contact your GitLab administrator if you think this is a mistake.
</p>
<div class="action-container">
<form class="form-inline-flex" action="/search" accept-charset="UTF-8" method="get"><div class="field">
<input type="search" name="search" id="search" value="" placeholder="Search for projects, issues, etc." class="form-control gl-rounded-lg" />
</div>
<button type="submit" class="gl-button btn btn-md btn-confirm "><span class="gl-button-text">
Search

</span>

</button></form></div>
<nav>
<ul class="error-nav">
<li>
<a href="/">Home</a>
</li>
<li>
<a href="/users/sign_in?redirect_to_referer=yes">Sign In / Register</a>
</li>
<li>
<a href="/help">Help</a>
</li>
</ul>
</nav>

</div>

</div>
<script nonce="nMSUVLNItAyIfghvWX3yuw==">
//<![CDATA[
(function(){
  var goBackElement = document.querySelector('.js-go-back');

  if (goBackElement && history.length > 1) {
    goBackElement.removeAttribute('hidden');

    goBackElement.querySelector('button').addEventListener('click', function() {
      history.back();
    });
  }

  // We do not have rails_ujs here, so we're manually making a link trigger a form submit.
  document.querySelector('.js-sign-out-link')?.addEventListener('click', (e) => {
    e.preventDefault();
    document.querySelector('.js-sign-out-form')?.submit();
  });
}());

//]]>
</script></body>
</html>
