/**
 * Generate DOM nodes
 *
 * @param {string} tag
 * @param {object|Array|string} attributes
 * @param {Array|string} children
 */
function h(tag, attributes, children) {
  console.assert(tag != null, "tag missing");
  if (typeof attributes === 'string' || Array.isArray(attributes)) {
    children = attributes;
    attributes = undefined;
  }

  let e = null;
  let separator = null;
  for (let part of tag.matchAll(/[^#.]+|[#.]+/g)) {
    part = part[0].trim();
    if (e === null) {
      e = document.createElement(part);
    } else if (separator === null) {
      console.assert(part === '#' || part === '.');
      separator = part;
    } else {
      if (separator === '#') {
        e.id = part;
      } else if (separator === '.') {
        e.classList.add(part);
      }
      separator = null;
    }
  }

  if (attributes) {
    for (const [key, value] of Object.entries(attributes)) {
      e.setAttribute(key, value);
    }
  }

  if (typeof children === 'string') {
    e.textContent = children;
  } else {
    for (let child of children ?? []) {
      if (typeof child === 'string') {
        child = document.createTextNode(child);
      }
      else if (Array.isArray(child)) {
        child = h(...child);
      }
      e.appendChild(child)
    }
  }
  return e;
}

const playerList = h('div.player-list');

const registerNameInput = h('input', { maxlength: 20 });
const registerButton = h('button', "⏎");
const registerStatusText = h('span', "");
const registerForm = h('div.register-form.hidden', [registerNameInput, registerStatusText, registerButton]);
function register() {
  if (registerNameInput.value.trim() === '') {
    return;
  }
  registerForm.classList.add('loading');
  fetch('register', {
    method: 'POST',
    body: JSON.stringify({
      username: registerNameInput.value,
    }),
  }).then(res => {
    if (!res.ok) {
      return Promise.reject(res);
    }
  }).catch((error) => {
    registerForm.classList.remove('loading');
    if (typeof error.json === "function") {
      error.json().then(json => {
        if (json.error) {
          registerStatusText.textContent = json.error;
        } else {
          registerStatusText.textContent = "Unknown error"
        }
      });
    } else {
      registerStatusText.textContent = "Unknown error"
    }
  });
}
registerButton.addEventListener('click', register);
registerNameInput.addEventListener('keydown', (ev) => {
  if (ev.key === 'Enter') {
    register();
  }
})

const cardValues = [0, 1, 2, 3, 5, 8, 13, 99, "?", "☕"].map(x => String(x));
const cardContainer = h('div.card-container.hidden', cardValues.map(value => {
  const card = h('div.card.selectable', value);
  card.addEventListener('click', () => {
    const selected = cardContainer.querySelector('.card.selected');
    if (!card.hasAttribute('disabled') && selected !== card) {
      if (selected) {
        selected.classList.remove('selected');
      }
      card.classList.add('selected');
      fetch('choose', {
        method: 'POST',
        body: JSON.stringify({ value }),
      });
    }
  });
  if (value === "☕") {
    card.title = "Hot beverage";
  }
  return card;
}));

const resultText = h('span.result-text.invisible', "")
const revealButton = h('button.hidden.hover-checkmark', { disabled: "" }, "")
const clearButton = h('button.hidden', "♻") // recycle
const centerArea = h('div.center-area', [
  resultText,
  revealButton,
  clearButton,
  ['div.invisible'], // keeps the buttons in the center
])
revealButton.onclick = function () {
  fetch("reveal");
}
clearButton.onclick = function () {
  fetch("clear");
}

const main = h('main.hidden', [
  ['div.stacking', [
    playerList,
    centerArea,
  ]],
  registerForm,
  cardContainer,
]);

document.body.appendChild(main);

async function fetchStatus(counter) {
  return fetch("status", {
    method: "POST",
    body: JSON.stringify({
      lastCounter: counter,
    }),
  })
    .then(res => {
      if (!res.ok) {
        return Promise.reject(res);
      }
      return res.json();
    })
    .then(res => {
      if (res.username) {
        registerNameInput.value = res.username;
        registerForm.classList.add('hidden');
        cardContainer.classList.remove('hidden');
      } else {
        cardContainer.classList.add('hidden');
        registerForm.classList.remove('hidden');
        registerForm.classList.remove('loading');
      }
      playerList.innerHTML = "";
      let hasAtleastOneCard = false
      if (res.users) {
        for (const user of res.users) {
          playerList.appendChild(
            h('div.player-container', [
              ['div.username', String(user.name)],
              user.card != null ? ['div.card', user.card] : ['div.card-placeholder'],
            ])
          );
          hasAtleastOneCard = hasAtleastOneCard || user.card != null;
        }
      }
      if (res.result) {
        revealButton.classList.add('hidden');
        if (clearButton.classList.contains('hidden')) {
          clearButton.classList.remove('hidden');
          clearButton.setAttribute('disabled', '');
          window.setTimeout(() => {
            clearButton.classList.remove('locked');
            clearButton.removeAttribute('disabled');
          }, 1000)
        }
        resultText.textContent = res.result;
        resultText.classList.remove('invisible');
        cardContainer.querySelectorAll('.card').forEach(card => {
          card.setAttribute('disabled', '');
        })
      } else {
        clearButton.classList.add('hidden');
        revealButton.classList.toggle('hidden', !res.users || res.users.length === 0);
        resultText.textContent = "";
        resultText.classList.add('invisible');
        cardContainer.querySelectorAll('.card').forEach(card => {
          if (card.hasAttribute('disabled')) {
            card.removeAttribute('disabled');
            card.classList.remove('selected');
          }
        })
        if (hasAtleastOneCard) {
          revealButton.removeAttribute('disabled');
        } else {
          revealButton.setAttribute('disabled', '');
        }
      }
      return res.counter;
    })
    .then(counter => window.setTimeout(fetchStatus, 200, counter))
    .catch(() => window.setTimeout(fetchStatus, 5000, counter))
}

fetchStatus(0).then(() => {
  main.classList.remove('hidden');
  setTimeout(() => registerNameInput.focus(), 200); // wait for element to become visible
})

