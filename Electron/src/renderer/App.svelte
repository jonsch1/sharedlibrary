<script lang="ts">
  import SharedApp from '../../../Shared/App.svelte';
  import { desktopCapabilities } from '../../../Shared/app';
  import appIcon from './assets/app-icon.png';
</script>

<SharedApp
  api={window.sharedLibrary}
  capabilities={desktopCapabilities}
  desktopEvents={window.sharedLibraryDesktopEvents}
  {appIcon}
/>
