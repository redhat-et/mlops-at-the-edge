# Instructions

1. Build the base containerdisk OCI image for Kubevirt that contains the FlightCtl agent and other dependencies. Run the ```build.sh``` script in the ```build-image``` folder. You must pass the OCI registry where the generated image should be stored and provide the username or organisation where the image will be hosted. 

Example
```
./build-image/build.sh quay.io my-user
```

2. Create and register a fleet of devices with FlightCtl via the ```./create-fleet/create-fleet.sh``` script. The script takes the containerdisk generated previously as a parameter. 

Example
```
./create-fleet/create-fleet.sh quay.io/my-user/diskimage-qcow2:v1
```

3. Monitor the Kubevirt VMs with the commands:

- ```kubectl get vm```
- ```kubectl get vmi```

The login credentials for all VMs are the same; user = dev, password = mlops

4. Access the FlightCtl UI via the URL returned by the create script.

5. When finished delete the VMs via ```./create-fleet/delete-fleet.sh```.