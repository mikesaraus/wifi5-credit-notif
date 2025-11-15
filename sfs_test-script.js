document.addEventListener('DOMContentLoaded', () => {
  setTimeout(() => {
    let wifi_interface = {
      eth1: { id: 'main', name: 'Main PISOWIFI' },
      'vlan.12': { id: 'main', name: 'Sub PISOWIFI' },
      // Add more interfaces as needed
    }

    document.querySelector('.content-wrapper .card .dropdown-toggle')?.click()

    setTimeout(() => {
      const clientInt = document
        .querySelector('.content-wrapper .card .clientInfo tr:nth-child(3) > td:last-child')
        ?.textContent?.trim()
      const currentWifiID = wifi_interface[clientInt]?.id || 'main'
      document.getElementById(currentWifiID)?.click()
    }, 500)
  }, 3000)
})
