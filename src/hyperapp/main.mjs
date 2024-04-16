import { h, text, app } from "./hyperapp.js"

function fetchStatus(counter) {
  return fetch("status", {
    method: "POST",
    body: JSON.stringify({
      lastCounter: counter,
    }),
  }).then(res => {
    if (!res.ok) {
      return Promise.reject(res);
    }
    return res.json();
  })
}

const HandleNewState = (state, res) => {
  const justRevealedResult = !state.result && res.result;
  return [
    {
      counter: res.counter,
      users: res.users,
      username: res.username,
      result: res.result,
      selectedCard: res.result ? undefined : state.selectedCard,
      clearButtonDisabled: state.clearButtonDisabled || justRevealedResult,
    },
    justRevealedResult &&
    (dispatch => window.setTimeout(() => dispatch(state => ({ ...state, clearButtonDisabled: false })), 1000))
  ]
}

const fetchStatusContinuously = (dispatch, { counter }) => {
  fetchStatus(counter)
    .then(res => {
      dispatch(HandleNewState, res)
      window.setTimeout(() => dispatch(state => [state, [fetchStatusContinuously, state]]), 200)
    })
    .catch(() => window.setTimeout(() => dispatch(state => [state, [fetchStatusContinuously, state]]), 5000))
}

const RegisterError = (state, errorMessage) => ({
  ...state,
  registerErrorMessage: errorMessage
})

const Register = state => {
  const input = document.getElementById("register-input")
  const name = input.value
  if (name.trim() === "") {
    return state
  }
  return [state,
    dispatch => fetch('register', {
      method: 'POST',
      body: JSON.stringify({
        username: name,
      }),
    }).then(res => {
      if (!res.ok) {
        return Promise.reject(res);
      }
    }).catch((error) => {
      if (typeof error.json === "function") {
        error.json().then(json => {
          if (json.error) {
            dispatch(RegisterError, json.error)
          } else {
            dispatch(RegisterError, "Unknown error")
          }
        });
      } else {
        dispatch(RegisterError, "Unknown error")
      }
    })
  ]
}

const ChooseCard = (state, value) =>
  state.selectedCard === value ? state : [
    { ...state, selectedCard: value },
    () => fetch('choose', {
      method: 'POST',
      body: JSON.stringify({ value: String(value) }),
    })
  ]

const Reveal = state => [
  state,
  () => fetch("reveal"),
]

const Clear = state => [
  state,
  () => fetch("clear"),
]

fetchStatus(0).then(initialStatus => {
  app({
    init: [
      { ...initialStatus, selectedCard: null },
      [fetchStatusContinuously, initialStatus]
    ],
    view: (state) => h("main", {}, [
      h("div", { class: "stacking" }, [

        h("div", { class: "player-list" },
          state.users.map(user => h('div', { class: "player-container" }, [
            h('div', { class: "username" }, text(user.name)),
            user.card != null
              ? h('div', { class: "card" }, text(user.card))
              : h('div', { class: "card-placeholder" }),
          ]))),

        h("div", { class: "center-area" }, [
          h("span", { class: "result-text" }, text(state.result ?? "")),
          !state.result
            ? h("button", { class: "hover-checkmark", onclick: Reveal, disabled: !state.users.some(user => user.card != null) })
            : h("button", { onclick: Clear, disabled: state.clearButtonDisabled }, text("♻")),
          h("div", { class: "invisible" }),
        ]),
      ]),

      !state.username
        ?
        h("div", { class: "register-form" }, [
          h("input", {
            autofocus: true,
            maxlength: 20,
            id: "register-input",
            onkeydown: (state, ev) => ev.key === "Enter" ? Register : state,
          }),
          state.registerErrorMessage &&
          h("span", {}, text(state.registerErrorMessage)),
          h("button", { onclick: Register }, text("⏎")),
        ])
        :
        h("div", { class: "card-container" },
          [0, 1, 2, 3, 5, 8, 13, 99, "?", "☕"].map(value =>
            h("div", {
              class: { card: true, selectable: true, selected: value === state.selectedCard },
              onclick: (state, ev) => ev.target.disabled ? state : [ChooseCard, value],
              disabled: state.result,
              title: value === "☕" ? "Hot beverage" : undefined,
            }, text(value))))
    ]),
    node: document.getElementById("app"),
  })
})
