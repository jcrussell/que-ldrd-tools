# Usage

This assumes that you have minimega and the QUE repo cloned in the same
directory, for example:

    repos/
        minimega/
        que-ldrd/

You must have built minimega first using `all.bash`.

## Running vmbetter

We have a wrapper script, `vmbetter.bash` that wraps `vmbetter` to simplify
building images. To build all images, run:

```bash
bash vmbetter.bash que que_host_ccc que_host_carnac que_physical
```

# Images

## que

VM image based on the miniccc image with additional packages for ApacheBench
(ab), perfsonar, and sysdig. Disables DHCP since we use static IPs so we can
reduce the VM/container start up times.

## que_host_ccc, que_host_carnac

Host image for CCC and Carnac, respectively. Includes additional packages for
analyses including parallel, sysdig, and scipy.

## que_physical

Host image for physical tests on CCC. Includes packages for instrumentation and
ApacheBench similar to the que VM image.
