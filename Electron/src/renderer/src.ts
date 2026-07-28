import '@fontsource-variable/dm-sans';
import '@fontsource-variable/fira-code';
import '@fontsource-variable/geist';
import '@fontsource-variable/geist-mono';
import '@fontsource-variable/inter';
import '@fontsource-variable/jetbrains-mono';
import '@fontsource-variable/lora';
import '@fontsource-variable/merriweather';
import '@fontsource-variable/montserrat';
import '@fontsource-variable/open-sans';
import '@fontsource-variable/outfit';
import '@fontsource-variable/oxanium';
import '@fontsource-variable/playfair-display';
import '@fontsource-variable/plus-jakarta-sans';
import '@fontsource-variable/quicksand';
import '@fontsource-variable/roboto';
import '@fontsource-variable/roboto-mono';
import '@fontsource-variable/source-code-pro';
import '@fontsource-variable/source-serif-4';
import '@fontsource/antic';
import '@fontsource/architects-daughter';
import '@fontsource/ibm-plex-mono';
import '@fontsource/libre-baskerville';
import '@fontsource/poppins';
import '@fontsource/space-mono';
import '@fontsource/ubuntu-mono';
import './styles.css';
import { mount } from 'svelte';
import App from './App.svelte';

mount(App, {
  target: document.getElementById('app')!
});
