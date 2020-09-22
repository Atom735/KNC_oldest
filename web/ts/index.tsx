import React from 'react';
import ReactDOM from 'react-dom';
import App from './App';

navigator.serviceWorker.register('./sw.bundle.js', { scope: './' })
  .then((reg) => {
    // регистрация сработала
    console.info('Registration succeeded. Scope is ' + reg.scope);
  }).catch((error) => {
    // регистрация прошла неудачно
    console.error('Registration failed with ' + error);
  });


ReactDOM.render(
  <App />,
  document.querySelector('#root'),
);
