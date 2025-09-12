function togglePassword() {
    const passwordInput = document.getElementById('password');
    const toggleBtn = document.querySelector('.toggle-password');
    
    if (passwordInput.type === 'password') {
        passwordInput.type = 'text';
        toggleBtn.textContent = '🙈';
    } else {
        passwordInput.type = 'password';
        toggleBtn.textContent = '👁️';
    }
}

function showStatus(message, isError = false) {
    const statusDiv = document.getElementById('status');
    statusDiv.className = `status-message ${isError ? 'error' : 'success'} show`;
    statusDiv.textContent = message;
    
    if (!isError) {
        setTimeout(() => {
            statusDiv.classList.remove('show');
        }, 5000);
    }
}

function validateForm(formData) {
    const ssid = formData.get('ssid').trim();
    const password = formData.get('password').trim();
    const apiKey = formData.get('apiKey').trim();
    
    if (!ssid) {
        throw new Error('WiFi network name is required');
    }
    
    if (!password) {
        throw new Error('WiFi password is required');
    }
    
    if (password.length < 8) {
        throw new Error('WiFi password must be at least 8 characters');
    }
    
    if (!apiKey) {
        throw new Error('API key is required');
    }
    
    if (apiKey.length < 10) {
        throw new Error('API key seems too short. Please check it.');
    }
    
    return { ssid, password, apiKey };
}

document.getElementById('setupForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    
    const submitBtn = document.getElementById('submitBtn');
    const btnText = submitBtn.querySelector('.btn-text');
    const btnLoader = submitBtn.querySelector('.btn-loader');
    const statusDiv = document.getElementById('status');
    statusDiv.classList.remove('show');
    
    try {
        const formData = new FormData(e.target);
        const validatedData = validateForm(formData);
        submitBtn.disabled = true;
        btnText.style.display = 'none';
        btnLoader.style.display = 'inline-flex';
        const params = new URLSearchParams(formData);
        const response = await fetch('/configure', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: params
        });
        
        const responseText = await response.text();
        
        if (!response.ok) {
            throw new Error(responseText || `Server error: ${response.status}`);
        }
        
        showStatus('OKAY' + responseText);
        
        setTimeout(() => {
            showStatus('🔄 Device is switching to WiFi mode. You may lose connection temporarily.');
        }, 2000);
        
    } catch (error) {
        showStatus('X' + error.message, true);
    } finally {
        submitBtn.disabled = false;
        btnText.style.display = 'inline';
        btnLoader.style.display = 'none';
    }
});

document.addEventListener('DOMContentLoaded', () => {
    document.getElementById('ssid').focus();
});

document.querySelectorAll('input').forEach((input, index, inputs) => {
    input.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') {
            e.preventDefault();
            const nextInput = inputs[index + 1];
            if (nextInput) {
                nextInput.focus();
            } else {
                document.getElementById('setupForm').requestSubmit();
            }
        }
    });
});

document.getElementById('ssid').addEventListener('input', (e) => {
    const input = e.target;
    if (input.value.trim().length > 0) {
        input.style.borderLeft = '4px solid #4CAF50';
    } else {
        input.style.borderLeft = '';
    }
});

document.getElementById('password').addEventListener('input', (e) => {
    const input = e.target;
    if (input.value.length >= 8) {
        input.style.borderLeft = '4px solid #4CAF50';
    } else if (input.value.length > 0) {
        input.style.borderLeft = '4px solid #FFC107';
    } else {
        input.style.borderLeft = '';
    }
});

document.getElementById('apiKey').addEventListener('input', (e) => {
    const input = e.target;
    if (input.value.trim().length >= 10) {
        input.style.borderLeft = '4px solid #4CAF50';
    } else if (input.value.length > 0) {
        input.style.borderLeft = '4px solid #FFC107';
    } else {
        input.style.borderLeft = '';
    }
});