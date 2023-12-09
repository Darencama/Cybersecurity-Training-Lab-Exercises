


## Title: Exploiting a Vulnerable Web Application 

### Summary: In this lab I will be demonstrating how to exploit a vulnerable web application. I will be utilizing an external kali attack virtual machine to exploit the web application. I will also be using a armitage which ties to metasploit to exploit a machine utilizing XAMPP WebDAV PHP Upload

### Steps:
- Use nmap to scan a network.
- Use Metasploit and Armitage to exploit a common web server vulnerability.
- Use Meterpreter to breach a system.

### Results:
First and foremost we will run a scan on the firewall for open ports. After we complete an intense scan. We will begin on using the metasploit XAMPP exploit. We will add the host into the armitage, then select the exploit and launch it. I will then find a route to the victims (LAN). The first victim will be exploited and we will then add another host and attack that host using a SMB attack.


<p align="center">
Run nmap scan in zenmap: <br/>

  ![Screenshot (99)](https://github.com/Darencama/Cybersecurity-Training-Lab-Exercises/assets/134806131/924b257d-f70b-4641-8431-7543dc2fd328)

<p align="center">
Add host in armitage: <br/>
  
  ![Screenshot (101)](https://github.com/Darencama/Cybersecurity-Training-Lab-Exercises/assets/134806131/9d76986c-82fd-40a0-94bc-ea2039d5b3ab)

<p align="center">
Add both hosts and exploit them: <br/>
  
  ![Screenshot (102)](https://github.com/Darencama/Cybersecurity-Training-Lab-Exercises/assets/134806131/79f2d3cc-221a-46e2-b0ab-be0b3bc2ff52)
